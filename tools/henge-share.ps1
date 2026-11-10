# Henge: share a folder on this PC with a Henge virtual Mac, in one go.
#
#   irm https://raw.githubusercontent.com/skyfish-dev/Henge/pointer-follow/tools/henge-share.ps1 | iex
#
# It shares the folder (the Desktop unless you pick another) with a separate sign-in that can only reach that
# folder, lets file sharing through the firewall from this network and from Tailscale only, optionally sets up
# Tailscale for using it away from home, then shows a code: scan it with the iPhone's Camera (or in Henge,
# Settings, Computers, Scan Code) and Henge adds the PC. Run it again any time; it picks up where it left off.
# To undo it: run it with -Remove.

param([string]$Folder = "", [switch]$Remove, [switch]$NoTailscale)

$ErrorActionPreference = "Stop"
$ScriptUrl = "https://raw.githubusercontent.com/skyfish-dev/Henge/pointer-follow/tools/henge-share.ps1"
$User = "henge"
$RuleName = "Henge file sharing"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($text) { Write-Host ""; Write-Host "  $text" -ForegroundColor Cyan }

# Changing sharing, accounts and the firewall needs an administrator: ask once, then carry on in that window.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    if (-not $Folder) { $Folder = [Environment]::GetFolderPath("Desktop") }
    $self = Join-Path $env:TEMP "henge-share.ps1"
    if ($PSCommandPath) { Copy-Item $PSCommandPath $self -Force }
    else { Invoke-RestMethod $ScriptUrl -OutFile $self } # run as irm ... | iex: fetch it again to run as a file
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-File", "`"$self`"", "-Folder", "`"$Folder`"")
    if ($Remove) { $arguments += "-Remove" }
    if ($NoTailscale) { $arguments += "-NoTailscale" }
    Say "Henge needs to change sharing settings: choose Yes when Windows asks." Yellow
    Start-Process powershell -Verb RunAs -ArgumentList $arguments
    return
}

if ($Remove) {
    Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq "Henge" } | ForEach-Object {
        Remove-SmbShare -Name $_.Name -Force
        Say "Stopped sharing $($_.Path)"
    }
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) { Remove-LocalUser -Name $User; Say "Removed the $User sign-in" }
    Say "Done: Henge can no longer reach this PC." Green
    return
}

Clear-Host
Say ""
Say "  Henge: save from your virtual Mac to this PC" White
Say "  ---------------------------------------------"

if (-not $Folder) { $Folder = [Environment]::GetFolderPath("Desktop") }
if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "There's no folder at $Folder" }
$Folder = (Resolve-Path -LiteralPath $Folder).Path
$Leaf = Split-Path $Folder -Leaf
$Share = "Henge-" + ($Leaf -replace '[^A-Za-z0-9_-]', '')
if ($Share -eq "Henge-") { $Share = "Henge-Files" }

# 1. A sign-in just for Henge. Not your own: a Microsoft account's password and PIN make sharing awkward, and
#    this one can only reach the shared folder. A new password each run; the code carries it to the iPhone.
Step "1/5  A sign-in for Henge"
$chars = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
$bytes = New-Object byte[] 20
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$Password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
$secure = ConvertTo-SecureString $Password -AsPlainText -Force
if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $User -Password $secure -PasswordNeverExpires $true
} else {
    New-LocalUser -Name $User -Password $secure -PasswordNeverExpires -AccountNeverExpires `
        -FullName "Henge" -Description "Lets a Henge virtual Mac save to a shared folder" | Out-Null
}
Enable-LocalUser -Name $User
# Off the sign-in screen: nobody signs in to Windows with it.
$hide = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList"
New-Item -Path $hide -Force | Out-Null
New-ItemProperty -Path $hide -Name $User -Value 0 -PropertyType DWord -Force | Out-Null
Say "      $User (only for the shared folder, hidden from the sign-in screen)"

# 2. The folder, shared read and write with that sign-in only.
Step "2/5  Sharing $Folder"
& icacls $Folder /grant "${User}:(OI)(CI)M" /Q | Out-Null
Set-Service -Name LanmanServer -StartupType Automatic
Start-Service -Name LanmanServer
Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Share -or ($_.Description -eq "Henge" -and $_.Path -eq $Folder) } |
    ForEach-Object { Remove-SmbShare -Name $_.Name -Force }
New-SmbShare -Name $Share -Path $Folder -ChangeAccess $User -Description "Henge" | Out-Null
Say "      shared as $Share"

# 3. The firewall: file sharing (TCP 445) from this network and from Tailscale's addresses, nothing else.
Step "3/5  Letting file sharing through the firewall"
Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort 445 -Action Allow `
    -RemoteAddress LocalSubnet, "100.64.0.0/10" -Profile Any | Out-Null
Say "      from this network and Tailscale only"

# 4. Tailscale, for saving to this PC from anywhere.
Step "4/5  Away from home (Tailscale)"
$ts = Join-Path $env:ProgramFiles "Tailscale\tailscale.exe"
$TailscaleIP = ""
if (-not $NoTailscale -and -not (Test-Path $ts)) {
    $answer = Read-Host "      Set up Tailscale too, to save to this PC from anywhere? It's free. (Y/n)"
    if ($answer -notmatch '^[nN]') {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Say "      Installing Tailscale..."
            & winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
        } else {
            Say "      Get Tailscale from https://tailscale.com/download/windows, then run this again." Yellow
        }
    }
}
if (Test-Path $ts) {
    $TailscaleIP = (& $ts ip -4 2>$null | Select-Object -First 1)
    if (-not $TailscaleIP) {
        Say "      Sign in to Tailscale: open the link below if a browser doesn't open by itself (any account works)."
        try { & $ts up --timeout=300s } catch { }
        for ($i = 0; $i -lt 10 -and -not $TailscaleIP; $i++) {
            $TailscaleIP = (& $ts ip -4 2>$null | Select-Object -First 1)
            if (-not $TailscaleIP) { Start-Sleep -Seconds 1 }
        }
    }
    if ($TailscaleIP) { Say "      Tailscale address $TailscaleIP" } else { Say "      Tailscale isn't signed in yet: run this again once it is." Yellow }
} else {
    Say "      skipped (this network only)"
}

# 5. This PC's address here, and the code for the iPhone.
Step "5/5  The code for your iPhone"
$lan = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
    ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ -and $_ -notlike "169.254.*" } | Select-Object -First 1
$hosts = @($lan, $TailscaleIP) | Where-Object { $_ }
if (-not $hosts) { throw "This PC has no network address: connect it to Wi-Fi or Ethernet, then run this again." }

function Enc($s) { [Uri]::EscapeDataString([string]$s) }
$name = $env:COMPUTERNAME
if ($Leaf -ne "Desktop") { $name = "$name $Leaf" }
$link = "henge://computer?n=$(Enc $name)&h=$(Enc ($hosts -join ','))&s=$(Enc $Share)&u=$(Enc $User)&p=$(Enc $Password)"

# The code is drawn in the browser, on this PC: the page loads a QR code library and nothing leaves the PC.
$page = Join-Path $env:TEMP "henge-code.html"
$linkJs = $link -replace '\\', '\\' -replace "'", "\'"
@"
<!doctype html><html><head><meta charset="utf-8"><title>Henge</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"></script>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0b0c10;color:#f2f3f7;
font:16px -apple-system,"Segoe UI",system-ui,sans-serif}
main{max-width:520px;padding:32px;text-align:center}
h1{font-size:24px;margin:0 0 8px}p{color:#9095a4;line-height:1.5;margin:8px 0}
#code{background:#fff;padding:20px;border-radius:16px;display:inline-block;margin:20px 0}
#code img{display:block;width:300px;height:300px;image-rendering:pixelated}
ol{text-align:left;color:#c9ccd6;line-height:1.7;padding-left:20px}
small{color:#6a6f7e}
</style></head><body><main>
<h1>Scan this with your iPhone</h1>
<p>$name &middot; $Folder</p>
<div id="code"></div>
<ol>
<li>Open the iPhone's <b>Camera</b> and point it at the code, then tap <b>Open in Henge</b>.<br><small>Or in Henge: Settings, Computers, Scan Code.</small></li>
<li>Tap <b>Add</b>.</li>
<li>On the virtual Mac, the PC is in <b>Henge Drives</b> in your home folder, and in every Save dialog.</li>
</ol>
<p><small>The code holds the password for the Henge sign-in on this PC. Close this page when you're done.</small></p>
</main><script>
var q = qrcode(0, 'M'); q.addData('$linkJs'); q.make();
document.getElementById('code').innerHTML = q.createImgTag(8, 0);
</script></body></html>
"@ | Set-Content -Path $page -Encoding UTF8
Start-Process $page

Say ""
Say "  Done. Scan the code in the browser window with your iPhone's Camera." Green
Say "  If the page doesn't open: $page"
Say ""
Say "  Shared folder: $Folder"
Say "  Addresses:     $($hosts -join ', ')"
Say "  To undo all of it later: run this again with -Remove"
Say ""
