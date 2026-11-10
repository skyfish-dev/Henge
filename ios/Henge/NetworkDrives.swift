import SwiftUI
import Network
import Security

/// Computers on the network whose shared folders the Mac saves to: a PC's Desktop, another Mac's
/// Documents, a NAS. The app keeps the list (passwords in the Keychain) and hands it to the helper in
/// macOS (host/share.c, /.henge/drives), which keeps each one mounted at ~/Henge Drives/<name>, so it
/// is in Finder and in every app's Save dialog. The guest's network goes out through this device, so
/// whatever this device reaches, the Mac reaches: the same Wi-Fi, or a VPN such as Tailscale.
struct NetworkDrive: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String       // what the Mac calls it: the folder in ~/Henge Drives
    var host: String       // an IP address or a name
    var share: String      // the shared folder's name on that computer
    var user: String       // empty for a guest
}

final class NetworkDrives: ObservableObject {
    static let shared = NetworkDrives()
    private static let listKey = "henge.drives"
    private static let keychainService = "com.henge.drive"

    @Published private(set) var drives: [NetworkDrive] = []
    /// What the helper last said about each, by name: nil "ok", or why it couldn't connect.
    @Published private(set) var status: [String: String] = [:]
    @Published private(set) var heardFromMac = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([NetworkDrive].self, from: data) {
            drives = saved
        }
    }

    // MARK: The list

    func save(_ drive: NetworkDrive, password: String?) {
        var drive = drive
        drive.name = Self.clean(drive.name)
        drive.host = Self.clean(Self.hostOnly(drive.host))
        drive.share = Self.clean(drive.share.trimmingCharacters(in: CharacterSet(charactersIn: "/\\")))
        drive.user = Self.clean(drive.user)
        if let i = drives.firstIndex(where: { $0.id == drive.id }) { drives[i] = drive } else { drives.append(drive) }
        if let password { Self.setPassword(password, for: drive.id) }
        persist()
    }

    func remove(_ drive: NetworkDrive) {
        drives.removeAll { $0.id == drive.id }
        Self.setPassword(nil, for: drive.id)
        persist()
    }

    /// A name no other drive has, from what the person typed or the share's own name.
    func uniqueName(_ wanted: String, except id: UUID) -> String {
        let base = Self.clean(wanted).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var name = base.isEmpty ? "Computer" : base, n = 2
        while drives.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(drives) { UserDefaults.standard.set(data, forKey: Self.listKey) }
        publish()
    }

    /// Hands the list to the engine, for the helper in macOS. Before a session and whenever it changes.
    func publish() {
        let lines = drives.map { d in
            [d.name, d.host, d.share, d.user, Self.password(for: d.id) ?? ""].map(Self.clean).joined(separator: "\t")
        }
        henge_share_set_drives(lines.joined(separator: "\n") + "\n")
    }

    /// Before a Mac starts: nothing heard from its helper yet, and the list ready for it.
    func sessionStarting() {
        heardFromMac = false
        status = [:]
        publish()
    }

    /// What the helper reported, while a Mac runs.
    func refreshStatus() {
        guard let raw = henge_share_drive_status() else { return }
        let text = String(cString: raw)
        free(raw)
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            found[parts[0]] = parts[1]
        }
        heardFromMac = true
        if found != status { status = found }
    }

    /// Tabs and line breaks would split the helper's lines.
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// "smb://192.168.1.20/Desktop" or "\\PC\Desktop" pasted into the address: just the computer.
    private static func hostOnly(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["smb://", "cifs://"] where h.lowercased().hasPrefix(prefix) { h.removeFirst(prefix.count) }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
        if let cut = h.firstIndex(where: { $0 == "/" || $0 == "\\" }) { h = String(h[..<cut]) }
        return h
    }

    /// The parts of a pasted address after the computer, as a share name, if there are any.
    static func shareIn(_ s: String) -> String? {
        let parts = s.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").filter { !$0.isEmpty }
        let rest = parts.drop { $0.lowercased() == "smb:" || $0.lowercased() == "cifs:" }.dropFirst()
        return rest.first
    }

    // MARK: Keychain

    static func password(for id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for id: UUID) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: id.uuidString]
        SecItemDelete(match as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: Checking

    /// Whether this device reaches the computer's file sharing (SMB, port 445). The Mac reaches what this device does.
    static func check(_ host: String) async -> Result<Void, CheckError> {
        let host = hostOnly(host)
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: 445) else { return .failure(.noAddress) }
        return await withCheckedContinuation { done in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let once = Once()
            let finish: (Result<Void, CheckError>) -> Void = { result in
                guard once.first() else { return }
                connection.cancel()
                done.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(.unreachable(error.localizedDescription)))
                case .waiting(let error):
                    if case .posix(let code) = error, code == .ECONNREFUSED { finish(.failure(.refused)) }
                    else if case .dns = error { finish(.failure(.noName)) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(.failure(.timedOut)) }
        }
    }

    enum CheckError: Error {
        case noAddress, refused, noName, timedOut, unreachable(String)

        var text: String {
            switch self {
            case .noAddress: return "Enter the computer's address."
            case .refused: return "The computer is there but file sharing is off. Turn on sharing for the folder (see How to Set Up)."
            case .noName: return "No computer by that name here. Use its IP address instead."
            case .timedOut: return "No answer. Check the computer is on and on the same Wi-Fi, that its firewall allows File and Printer Sharing, and that Henge may use the local network (iOS Settings, Privacy & Security, Local Network)."
            case .unreachable(let why): return "It couldn't be reached: \(why)"
            }
        }
    }

    private final class Once {
        private var done = false
        private let lock = NSLock()
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

// MARK: - Settings, Computers

/// The list of computers, as Settings shows it. Also in a running Mac's Details, with how each one is doing.
struct NetworkDrivesView: View {
    @ObservedObject private var store = NetworkDrives.shared
    @State private var editing: NetworkDrive?
    @State private var adding = false
    var running = false
    /// In a running Mac's Details: types the Set Up Command into the Mac's Terminal.
    var typeSetUp: (() -> Void)? = nil

    var body: some View {
        Form {
            Section {
                if store.drives.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("No computers yet", systemImage: "desktopcomputer")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add a computer to save files from the Mac straight to it, like your laptop's Desktop.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.drives) { drive in
                    Button { editing = drive } label: { row(drive) }
                        .foregroundStyle(Desk.text)
                }
                .onDelete { offsets in offsets.map { store.drives[$0] }.forEach(store.remove) }
                Button { adding = true } label: { Label("Add Computer", systemImage: "plus.circle.fill") }
            } footer: {
                Text("On the Mac, each one is in Finder under Henge Drives in your home folder, and in every app's Save dialog. Drag Henge Drives to Finder's sidebar to keep it one click away.")
            }
            .listRowBackground(Desk.card)

            if running, !store.drives.isEmpty, oldHelper, let typeSetUp {
                Section {
                    Button { typeSetUp() } label: { Label("Update Henge's Helper", systemImage: "arrow.down.circle") }
                } footer: {
                    Text("The helper on this Mac is from before Henge could connect computers. Open Terminal on the Mac, tap this, then press Return.")
                }
                .listRowBackground(Desk.card)
            }
            Section {
                NavigationLink { NetworkDrivesGuide() } label: { Label("How to Set Up", systemImage: "book") }
            } footer: {
                Text("Windows, a Mac or Linux, at home or away. The Mac needs Henge's helper (Details, Type the Set Up Command), installed again after Henge updates.")
            }
            .listRowBackground(Desk.card)
        }
        .scrollContentBackground(.hidden)
        .background(Desk.page)
        .navigationTitle("Computers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { NetworkDriveEditor(drive: nil) }
        .sheet(item: $editing) { NetworkDriveEditor(drive: $0) }
        .task {
            guard running else { return }
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                waited = true
            }
            while !Task.isCancelled {
                store.refreshStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func row(_ drive: NetworkDrive) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 20))
                .foregroundStyle(Desk.accentLight)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(drive.name).font(.system(size: 16, weight: .medium))
                Text("\(drive.host) › \(drive.share)").font(.footnote).foregroundStyle(.secondary)
                if running, let line = statusLine(drive) {
                    Text(line.text).font(.footnote).foregroundStyle(line.color)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Desk.faint)
        }
        .padding(.vertical, 2)
    }

    /// The helper answers but has never said how the computers are: one from before it could mount them.
    private var oldHelper: Bool { Sharing.helperRunning && !store.heardFromMac && waited }
    @State private var waited = false

    private func statusLine(_ drive: NetworkDrive) -> (text: String, color: Color)? {
        guard store.heardFromMac else {
            if oldHelper { return ("Update Henge's helper (below)", Desk.warn) }
            return Sharing.helperRunning ? ("Connecting…", Desk.dim) : ("Set up Henge's helper on the Mac first", Desk.warn)
        }
        switch store.status[drive.name] {
        case nil: return ("Connecting…", Desk.dim)
        case "ok"?: return ("Connected", Desk.good)
        case let why?: return (why, Desk.bad)
        }
    }
}

/// Adding a computer, or changing one.
struct NetworkDriveEditor: View {
    let original: NetworkDrive?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var share: String
    @State private var user: String
    @State private var password: String
    @State private var guest: Bool
    @State private var checking = false
    @State private var checked: String?
    @State private var checkedOK = false
    @State private var confirmRemove = false

    init(drive: NetworkDrive?) {
        original = drive
        _name = State(initialValue: drive?.name ?? "")
        _host = State(initialValue: drive?.host ?? "")
        _share = State(initialValue: drive?.share ?? "")
        _user = State(initialValue: drive?.user ?? "")
        _password = State(initialValue: drive.flatMap { NetworkDrives.password(for: $0.id) } ?? "")
        _guest = State(initialValue: drive.map { $0.user.isEmpty } ?? false)
    }

    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !share.trimmingCharacters(in: .whitespaces).isEmpty
            && (guest || !user.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address, e.g. 192.168.1.20", text: $host)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: host) { _, typed in
                            // A whole path pasted in (\\PC\Desktop, smb://PC/Desktop): the folder comes along.
                            if share.isEmpty, let found = NetworkDrives.shareIn(typed) { share = found }
                        }
                    TextField("Shared folder, e.g. Desktop", text: $share)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("Computer")
                } footer: {
                    Text("The computer's IP address (or name, such as MY-LAPTOP.local) and the name its folder is shared under.")
                }
                Section {
                    Toggle("Connect as Guest", isOn: $guest)
                    if !guest {
                        TextField("User name", text: $user)
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("The account on that computer: on Windows with a Microsoft account, its email address and password. The password stays in this \(Device.name)'s Keychain and goes only to your Mac.")
                }
                Section {
                    TextField(share.isEmpty ? "Name on the Mac" : share, text: $name)
                } header: {
                    Text("Name on the Mac")
                } footer: {
                    Text("Its folder in Henge Drives.")
                }
                Section {
                    Button {
                        checking = true
                        checked = nil
                        Task {
                            let result = await NetworkDrives.check(host)
                            checking = false
                            switch result {
                            case .success: checkedOK = true; checked = "This \(Device.name) reaches the computer's file sharing."
                            case .failure(let e): checkedOK = false; checked = e.text
                            }
                        }
                    } label: {
                        HStack {
                            Label("Check Connection", systemImage: "network")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(checking || host.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let checked {
                        Label(checked, systemImage: checkedOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(checkedOK ? Desk.good : Desk.warn)
                    }
                }
                if original != nil {
                    Section {
                        Button("Remove Computer", role: .destructive) { confirmRemove = true }
                    }
                }
            }
            .navigationTitle(original == nil ? "Add Computer" : "Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!canSave).fontWeight(.semibold)
                }
            }
            .confirmationDialog("Remove this computer?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let original { NetworkDrives.shared.remove(original) }
                    dismiss()
                }
            } message: {
                Text("The Mac lets go of it. Nothing on the computer is deleted.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        let store = NetworkDrives.shared
        var drive = original ?? NetworkDrive(name: "", host: "", share: "", user: "")
        drive.host = host
        drive.share = share
        drive.user = guest ? "" : user
        drive.name = store.uniqueName(name.isEmpty ? share : name, except: drive.id)
        store.save(drive, password: guest ? "" : password)
        dismiss()
    }
}

/// Step by step, for each kind of computer, and for away from home.
struct NetworkDrivesGuide: View {
    enum Kind: String, CaseIterable, Identifiable {
        case windows = "Windows", mac = "Mac", linux = "Linux"
        var id: String { rawValue }
    }

    @State private var kind = Kind.windows

    var body: some View {
        Form {
            Section {
                Picker("Computer", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            switch kind {
            case .windows: windows
            case .mac: mac
            case .linux: linux
            }
            onTheMac
            awayFromHome
            trouble
        }
        .scrollContentBackground(.hidden)
        .background(Desk.page)
        .navigationTitle("How to Set Up")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var windows: some View {
        Group {
            steps("1. Share a folder", [
                "On the PC, open File Explorer and find the folder to save into, for example Desktop (in C:\\Users\\you).",
                "Right-click it, choose Properties, then the Sharing tab, then Share….",
                "Your own account is listed as Owner. Click Share, then Done. Note the name after the last \\ under Network Path: that is the shared folder's name.",
            ])
            steps("2. Let the network in", [
                "Settings, Network & internet, Wi-Fi (or Ethernet), your network: set it to Private.",
                "Control Panel, Network and Sharing Center, Change advanced sharing settings: under Private, turn on Network discovery and File and printer sharing.",
            ])
            steps("3. Find the PC's address", [
                "Open Command Prompt and type ipconfig. The address is the IPv4 Address of your Wi-Fi or Ethernet adapter, such as 192.168.1.20.",
                "Or Settings, Network & internet, your network, Properties: IPv4 address.",
            ])
            steps("4. Your sign-in", [
                "User name: with a Microsoft account, its email address; with a local account, its name. Password: that account's password, not a PIN.",
                "Signing in with Windows Hello only? Set a password in Settings, Accounts, Sign-in options, or create a local account for sharing.",
            ])
        }
    }

    private var mac: some View {
        Group {
            steps("1. Share a folder", [
                "System Settings, General, Sharing: turn on File Sharing, then click ⓘ.",
                "Click + under Shared Folders and pick the folder, for example Desktop.",
                "Click Options… and check that SMB is on, and turn on your account under Windows File Sharing.",
            ])
            steps("2. Address and sign-in", [
                "The address is under the File Sharing ⓘ, as smb://… (an IP address, or a name ending in .local).",
                "Sign in with that Mac's user name and password.",
            ])
        }
    }

    private var linux: some View {
        Group {
            steps("1. Share a folder with Samba", [
                "Install Samba (sudo apt install samba on Ubuntu or Debian).",
                "Add a share to /etc/samba/smb.conf, for example: [Desktop] path = /home/you/Desktop, read only = no.",
                "Give your user a Samba password with sudo smbpasswd -a you, then sudo systemctl restart smbd.",
            ])
            steps("2. Address and sign-in", [
                "The address is from ip addr (inet, such as 192.168.1.20). Sign in with your user and the Samba password.",
            ])
        }
    }

    private var onTheMac: some View {
        steps("In Henge", [
            "Settings, Computers, Add Computer: enter the address, the shared folder's name and the sign-in, then Check Connection.",
            "Start your Mac. If you haven't yet, set up Henge's helper: Details, Type the Set Up Command, then Return in Terminal. After a Henge update, do it once more so the helper can mount computers.",
            "In a few seconds the computer shows as Connected in Details, Computers. On the Mac it's in your home folder, Henge Drives. In any Save dialog, pick it there (or drag Henge Drives to Finder's sidebar first).",
            "The first time, iOS asks whether Henge may find devices on the local network: choose Allow.",
        ], footer: "The iPhone and the computer must be on the same network, such as your home Wi-Fi. The computer must be on and awake.")
    }

    private var awayFromHome: some View {
        steps("Away from home", [
            "File sharing must never be opened to the internet. Use Tailscale, a free private network between your own devices, instead.",
            "Install Tailscale on the computer and sign in. Then install it in the virtual Mac too (tailscale.com/download, the macOS app) and sign in with the same account.",
            "In Henge, use the computer's Tailscale address (100.x.y.z, shown in Tailscale) as the address. It works from any Wi-Fi or cellular network, wherever the computer is.",
        ], footer: "Tailscale belongs in the virtual Mac rather than on the iPhone: iOS runs one VPN at a time, and LocalDevVPN may need that slot for JIT.")
    }

    private var trouble: some View {
        steps("If it doesn't connect", [
            "Check Connection fails: the computer is off or asleep, on another network, or its firewall blocks File and Printer Sharing.",
            "\"The user name or password was refused\": on Windows, use the account's password, not its PIN, and the email address for a Microsoft account.",
            "\"No shared folder by that name\": use the name after the last \\ in the Network Path Windows showed, not the folder's full path.",
            "Connected but not on the Mac: open Finder, Go, Home, then Henge Drives.",
        ])
    }

    private func steps(_ title: String, _ items: [String], footer: String? = nil) -> some View {
        Section {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
        .listRowBackground(Desk.card)
    }
}
