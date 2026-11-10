import UIKit
import GameController

/// Puts the Mac's pointer where iOS's own pointer is, so that there is one pointer and not two.
///
/// While iOS shows its own pointer (always on iPhone, where a mouse goes through AssistiveTouch; on iPad
/// when it won't lock the pointer away, as in a window), a mouse moved iOS's pointer with iOS's acceleration
/// and the Mac's with macOS's, and the two drifted apart: clicks landed where the Mac's pointer was, not
/// where iOS's was. The Mac's mouse is relative and macOS accelerates it, so one move seldom lands exactly.
/// So: move, see where the pointer went (henge_vm_pointer), and move again, learning how far macOS takes
/// each unit. Clicks wait until the pointer has arrived.
final class PointerFollow: NSObject {
    static let shared = PointerFollow()
    /// "auto" (follow whenever iOS shows its own pointer), "on", or "off" (the old relative mouse only).
    static let modeKey = "henge.mouse.follow"

    enum Mode: String, CaseIterable, Identifiable {
        case auto, on, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Automatic"
            case .on: return "Always"
            case .off: return "Never"
            }
        }
    }

    /// The Mac's screen in pixels, as henge_vm_pointer counts them.
    var screen = CGSize(width: 1920, height: 1080)

    private var target: (x: Int32, y: Int32)?
    private var link: CADisplayLink?
    private var gain: Double = 1                 // pixels the Mac's pointer goes for each unit sent
    private var sent: (dx: Int32, dy: Int32, fromX: Int32, fromY: Int32, at: CFTimeInterval)?
    private var stuck = 0                        // moves the pointer didn't answer
    private var pending: [() -> Void] = []
    private var deadline: CFTimeInterval = 0     // pending actions run by then, arrived or not
    private var idleSince: CFTimeInterval = 0
    private(set) var lastHover: CFTimeInterval = 0
    private var logged = 0

    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .auto
    }

    /// Whether the Mac's pointer follows iOS's now.
    var active: Bool {
        switch Self.mode {
        case .on: return true
        case .off: return false
        case .auto: return !Self.pointerLocked
        }
    }

    /// iPadOS hands the pointer over only to an app filling the screen; an iPhone never does.
    static var pointerLocked: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.activationState == .foregroundActive && $0.pointerLockState?.isLocked == true }
    }

    /// iOS's pointer has been seen hovering lately: it, not the mouse's raw motion, says where to go.
    var hoverDrives: Bool { active && CACurrentMediaTime() - lastHover < 0.5 }

    /// A hover of iOS's pointer, at a point given as 0...1 of the Mac's screen.
    func hovered(_ p: CGPoint) {
        lastHover = CACurrentMediaTime()
        aim(p)
    }

    /// Go to a point given as 0...1 of the Mac's screen.
    func aim(_ p: CGPoint) {
        guard active else { return }
        let x = Int32((min(max(p.x, 0), 1) * (screen.width - 1)).rounded())
        let y = Int32((min(max(p.y, 0), 1) * (screen.height - 1)).rounded())
        if logged < 12 {
            logged += 1
            HengeLog.log("input", "follow: aim \(x),\(y) gain \(String(format: "%.2f", gain))")
        }
        if target?.x != x || target?.y != y { stuck = 0 }
        target = (x, y)
        // A click waiting for a place to go now has one: give the pointer time to get there.
        if !pending.isEmpty { deadline = max(deadline, CACurrentMediaTime() + 0.2) }
        run()
    }

    /// Runs once the pointer has reached where it was sent, so that a click lands there. Without
    /// a place to go, it waits a moment for one: a mouse button can come before the touch that says where.
    /// A release (waitForPlace false) with nothing waiting and nowhere to go happens at once.
    func afterArriving(waitForPlace: Bool = true, _ action: @escaping () -> Void) {
        guard active else { action(); return }
        if !waitForPlace, target == nil, pending.isEmpty { action(); return }
        let now = CACurrentMediaTime()
        if pending.isEmpty { deadline = now + (target == nil ? 0.05 : 0.2) }
        pending.append(action)
        run()
    }

    /// The session ended: forget where it was going, and do what was waiting.
    func reset() {
        flush()
        target = nil
        sent = nil
        link?.invalidate()
        link = nil
    }

    private func run() {
        idleSince = CACurrentMediaTime()
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func flush() {
        let actions = pending
        pending.removeAll()
        actions.forEach { $0() }
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        guard let t = target else {
            if !pending.isEmpty, now >= deadline { flush() }
            if pending.isEmpty, now - idleSince > 1 { stop() }
            return
        }
        var x: Int32 = 0, y: Int32 = 0
        guard henge_vm_pointer(&x, &y) == 0 else { // no pointer yet: nothing to measure against
            target = nil
            flush()
            return
        }
        let ex = t.x - x, ey = t.y - y
        if abs(ex) <= 1 && abs(ey) <= 1 {
            sent = nil
            target = nil
            flush()
            return
        }
        if let s = sent {
            let movedX = x - s.fromX, movedY = y - s.fromY
            // Wait a few frames for the last move to show up.
            if movedX == 0 && movedY == 0 && now - s.at < 0.06 { return }
            if movedX == 0 && movedY == 0 {
                stuck += 1
            } else {
                stuck = 0
                // Learn from the axis that moved most. A move cut short by the screen's edge says little.
                let alongX = abs(s.dx) >= abs(s.dy)
                let d = Double(abs(alongX ? s.dx : s.dy)), m = Double(abs(alongX ? movedX : movedY))
                let atEdge = x <= 0 || y <= 0 || x >= Int32(screen.width) - 1 || y >= Int32(screen.height) - 1
                if d >= 3, m > 0, !atEdge { gain = min(max(0.5 * gain + 0.5 * m / d, 0.2), 5) }
            }
            sent = nil
        }
        if stuck >= 8 { // the Mac isn't moving its pointer (no pointer shown, or it is busy): give up on this one
            HengeLog.log("input", "follow: pointer didn't move, at \(x),\(y) for \(t.x),\(t.y)")
            target = nil
            stuck = 0
            flush()
            return
        }
        if !pending.isEmpty, now >= deadline { flush() }
        var dx = Int32((Double(ex) / gain).rounded()), dy = Int32((Double(ey) / gain).rounded())
        if dx == 0 && ex != 0 { dx = ex > 0 ? 1 : -1 }
        if dy == 0 && ey != 0 { dy = ey > 0 ? 1 : -1 }
        dx = min(max(dx, -400), 400)
        dy = min(max(dy, -400), 400)
        henge_vm_mouse_move(dx, dy)
        sent = (dx, dy, x, y, now)
        idleSince = now
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }
}
