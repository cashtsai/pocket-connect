# Pocket Connect: Ubuntu / Windows WSL2 preview

This package installs a real Pocket bridge on your own computer. It is not a
browser-only Console shortcut. It does not install or include AI subscriptions.
The existing macOS app/release is unchanged.

The service flags follow the existing Mac/Ubuntu installers: the local Console
is enabled, remote Console retains the Relay-only access policy, remote file
roots stay closed, and native Pocket can use the headless provider sign-in
endpoints after device authentication. No account, provider binary, paid Cloud
plan, managed-host enrollment or public tunnel is provisioned by this package.
Codex keeps the bridge's isolated Linux default; a separate managed-daemon
service and Mac desktop-app session parity are not supplied in this preview.

## Ubuntu 22.04+ / Debian 12+

1. Download the `.deb` and matching `SHA256SUMS` from the official Pocket Connect
   GitHub release. Run `sha256sum --ignore-missing -c *SHA256SUMS` in that folder.
2. Install with `sudo apt install ./pocket-connect_*_all.deb`.
3. As your **normal user**, run `pocket-connect install`. Or open **Pocket Connect
   Setup** in the app launcher. Python dependencies download from PyPI; internet
   is required. The installed service runs as you, never root.
4. Install your preferred agent using its official instructions and sign in on
   this Linux host. Run `pocket-connect doctor` to see detected tools. This preview
   does not automatically install model runtimes, copy credentials, or import
   sessions from another operating system.
5. The bridge binds **localhost** by default. For a trusted home LAN, explicitly
   run `pocket-connect install --lan`; permit only your trusted network in your
   firewall. For remote use, set up Tailscale on the host and phone, then Tailscale
   Serve to forward private HTTPS to `http://127.0.0.1:8081`. Do not use Funnel or
   public port forwarding as a substitute for private access. Verify connectivity
   before pairing. Installing Pocket does not alter firewall rules.
6. Run `pocket-connect pair` and scan the host QR in Pocket on your iPhone.
   The iPhone app/test access is required separately. Verify the QR offers a
   reachable host, then send a harmless test message and wait for a real reply.

Login starts the user service. For boot without login, explicitly enable linger:
`sudo loginctl enable-linger "$USER"`. A sleeping/offline host cannot run tasks.

For a headless Ubuntu host, set up the phone-reachable network route first and
run `pocket-connect pair --link`. This prints a private, single-use link valid
for 15 minutes; open it only on your own phone and never paste it into logs or
support tickets. A host without a reachable route returns an error, not a dead QR.
For the local browser Console, run `pocket-connect console`. On a headless host,
use an SSH local port forward and `pocket-connect console --url` privately.

## Windows 11 + WSL2 Ubuntu 24.04

This is a **WSL2 installer ZIP**, not a native Windows `.exe` service or signed
desktop GUI. Claude/Codex sessions live in WSL. Native Windows Codex/Claude app
sessions are **not** automatically shared with the Linux runtime.

1. Prepare WSL2: in Administrator PowerShell run
   `wsl --install -d Ubuntu-24.04`. Restart if Windows asks. Open Ubuntu once and
   create a normal Linux user/password. Do not use root as the default user.
2. Ensure WSL supports systemd (`wsl --version`, minimum 0.67.6). In Ubuntu,
   `systemctl --user show-environment` must work. If needed, merge
   `[boot]` / `systemd=true` into `/etc/wsl.conf`; preserve other settings.
   Save work before manually running `wsl --shutdown`, which stops ALL distros.
3. Check the ZIP SHA256 with `Get-FileHash -Algorithm SHA256 .\Pocket-Connect-*-windows-wsl2.zip`
   against the official release checksum. After checking its source/hash, unblock
   the downloaded ZIP in Windows file Properties if required, then extract it.
   Do not change your machine-wide execution policy or disable SmartScreen.
4. Double-click `Install.cmd` and review the confirmation. Linux `sudo` may ask
   for the password created in step 1. It installs Python prerequisites inside
   your selected distro, checks the bundled payload, and enables its user service.
   For an existing different distro: `powershell -File .\Pocket-Connect.ps1 -Distro Ubuntu -Action Install`.
   For a busy default port on the first install, add `-Port 8082` and point your
   private network forwarding to that same port. Reinstall retains the saved port.
5. Install/sign in to Claude Code or Codex **inside WSL**. Configure Tailscale
   **inside WSL** plus private Serve and on your phone. Installing Tailscale only
   on Windows does not automatically expose a localhost-only WSL service.
   Windows localhost forwarding permits the local pairing browser, but is NOT
   a phone-reachable route. No netsh, Hyper-V firewall or global WSL changes are made.
6. Run the installed script at `%LOCALAPPDATA%\PocketConnect\Pocket-Connect.ps1`
   with `-Action Pair`. It opens the local QR in the Windows browser. Check the
   reachable URL and pair the iPhone, then verify a real provider reply.
   Use `-Action Console` to open the authenticated local Console in Windows.

The installer starts a background WSL keepalive and adds a **current-user login** startup shortcut, not a pre-login
Windows service. Use `-NoAutostart` to opt out. `-Action Start` runs a foreground
WSL keepalive because systemd services alone do not keep a distro alive. Closing
that command, signing out, sleeping, or `wsl --shutdown` can interrupt work.

## Checks, update, removal

- `pocket-connect status`: authenticated bridge readiness, not model success.
- `pocket-connect doctor`: Python, systemd, installed state and provider tools.
- `pocket-connect logs`: recent service logs. Redact before sharing.
- `pocket-connect start` / `stop`: only this package's service, never another bridge.
- Port busy: leave the existing bridge alone; first install can use `--port 8082`.
- No systemd user bus: run from your normal login, check systemd and linger.
- No reply: check provider installation/login/eligibility and pending approvals.
- QR has no reachable host: configure the network route above first. Bridge health
  alone is not proof that the phone can connect.
- Update: install the next `.deb`/ZIP then rerun setup. It stages a new runtime;
  failed authenticated readiness restores the previous runtime. Tokens/data stay.
  No automatic updater fetches development branches or private repositories.
- Linux removal: `pocket-connect uninstall --yes`, then `sudo apt remove pocket-connect`.
  Windows: installed script `-Action Uninstall`. WSL, agent logins, tokens/history
  are retained; this intentionally does not delete your work.

This is a preview. Read release notes for actual tested platforms. A checksum
checks integrity, not publisher identity; use only the official release origin.

## Official references

- https://learn.microsoft.com/en-us/windows/wsl/install
- https://learn.microsoft.com/en-us/windows/wsl/systemd
- https://learn.microsoft.com/en-us/windows/wsl/networking
- https://tailscale.com/kb/1312/serve
- https://github.com/cashtsai/pocket-connect/releases

## Build

On Ubuntu with `dpkg-deb` and Python 3.10+:

```
python3 packaging/build_platforms.py --bridge-source /path/to/bridge --version 1.0.2-preview.2
```

Uses the existing private `POCKET_SANITIZE_TABLE` (or standard release location).
Only allowlisted tracked runtime files enter the payload. Missing sanitizer input,
dirty bridge checkout, residual identifiers or credential shapes stop the build.
Do not upload raw private bridge source or release secrets.
