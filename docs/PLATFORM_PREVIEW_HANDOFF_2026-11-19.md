# Ubuntu / Windows WSL2 platform preview handoff

## Release state

- Branch / PR: `codex/connect-linux-windows`, [PR 19](https://github.com/cashtsai/pocket-connect/pull/19), not merged.
- Published package source: `08fda6f86e55b30033ff4595c6ce01fbb51f6247`.
- Bundled runtime: `54e089e653766dd847e23ff3f7b6ff4e79290f3f`.
- Public [1.0.2-preview.2](https://github.com/cashtsai/pocket-connect/releases/tag/platforms-v1.0.2-preview.2), tag `platforms-v1.0.2-preview.2`.
- Owner approved following the existing Mac distribution process after the prior
  public-release approval question. Sanitized allowlisted payload only, through
  the established official public GitHub Releases channel.
- Public assets downloaded without authentication and checked against SHA256SUMS.
- Mac stable/latest remains v1.0.1. No production bridge, cloud host or iOS changes.
- Official website rollout is in the existing Lovable project
  `fb2af823-f900-488b-bdf6-f8ece7326f42`; download enablement follows public verification.

## Evidence and limitations

[Package build 44477635551](https://github.com/cashtsai/pocket-connect/actions/runs/44477635551):

- Ubuntu job PASSED: 14 unit tests, real Ubuntu24.04 x86_64 DEB installation,
  user systemd, token-authenticated readiness, invalid-token rejection, QR gate,
  actual Console HTML, headless link with a local test route, missing-XDG recovery,
  reinstall retains identity. User bus is an explicit DEB dependency.
- Windows shell job PASSED: PowerShell5.1/7 parsing and mocked WSL preflight.
- Windows WSL job CANCELLED: Ubuntu Base24.04.5 imported successfully on hosted
  WindowsServer2025, but the first Linux command stalled before Pocket setup.
  No real WSL lifecycle pass is claimed; this run's overall result is cancelled.
- CI-only follow-up `5a4b107` passed Ubuntu/shell checks in
  [44478729571](https://github.com/cashtsai/pocket-connect/actions/runs/44478729571),
  with WSL explicitly SKIPPED. Its rebuilt artifacts are NOT the public release.
- Earlier ARM64 Ubuntu24.04 container runtime/auth/reinstall smoke passed, without
  systemd/reboot/phone. This is not physical ARM64 platform qualification.

Real WSL attempts are now manual: dispatch the workflow with `wsl_integration=true`
on a capable disposable runner. The job has a time limit and does not make overall
green mean WSL passed. Inspect the actual job result. Release tag pushes should
not build again (tag paths filters do not prevent tag-triggered workflows).

## Public downloads

Use the release's **`SHA256SUMS`**, which matches actual public asset names.
GitHub normalized `~` to `.` in the uploaded DEB filename; the internal Debian
version and bytes are unchanged. The versioned `...-SHA256SUMS` is retained only
as the original CI-filename manifest. Never overwrite published package bytes.

| Public file | Bytes | SHA256 |
|---|---:|---|
| `pocket-connect_1.0.2.preview.2_all.deb` | 1596562 | `f0d34a56479228cd568a0d2137bd091abb2bf2a3f62990b129be5f781f5f3b11` |
| `Pocket-Connect-1.0.2-preview.2-windows-wsl2.zip` | 1886552 | `d5b6ace06d24a4041fb2174fc6863789642d50091ea8116c3781ccc655a3ffbb` |
| `Pocket-Connect-1.0.2-preview.2-linux.tar.gz` | 1878506 | `53abac2401a397988346b0838b723649b9e1b828d9da3722d46b2d87fcd69bac` |

The Linux tar's 66-file manifest and Windows nested manifest were independently
verified locally. ZIP embeds the exact same Linux archive. The builder applies
the existing Mac sanitizer plus independent privacy and credential-shape checks;
no live DB, logs, dotenv, private plist, credentials or raw private checkout ships.
The public standard `100.64.0.0/10` CIDR exemption is regression tested; actual
private host addresses remain blocked.

## Implementation map

- `packaging/build_platforms.py`: allowlisted runtime, sanitizer, integrity manifest.
- `packaging/build_deb_from_archive.py`: DEB, desktop entries, user-bus dependency.
- `packaging/linux/pocket-connect`: per-user runtime, staged install/recovery,
  systemd, private credentials, status/doctor, local Console, headless pairing.
- `packaging/windows/Pocket-Connect.ps1`: initialized WSL2 preflight, explicit
  dependency consent, custom first-install port, login shortcut and keepalive.
- `packaging/tests/test_windows_wsl.ps1`: disposable CI-only distro lifecycle
  attempt using checksum-pinned official Ubuntu Base, not a production installer.
- `packaging/README.md`: installation, reachability and troubleshooting.

## Mac / Cloud comparison

Console is enabled; remote browser access retains Relay-only policy and closed
file roots. Native Pocket provider sign-in routes require existing device auth.
Headless `pair --link` is private, single-use and 15 minutes, with an existing route.
No provider binaries/accounts/subscriptions, managed Codex daemon, paid Cloud
enrollment or Mac-style automatic tunnel is supplied. Linux Codex stays isolated;
native Windows/Mac desktop sessions are not automatically shared.

Default localhost; phone access needs private Tailscale Serve inside Linux/WSL or
explicit trusted-LAN opt-in. No firewall/global WSL edits. Windows keepalive starts
after user login, not before login. Linger is opt-in on Ubuntu. Removal keeps data.
Dependencies download at install time; runtime rollback does not snapshot the DB.

## Remaining acceptance

- Physical Windows11 WSL2 install, unsigned ZIP unblock, sudo, local browser launch,
  login/reboot/sleep behavior; actual phone pairing and streaming/approval/reconnect.
- Provider install/sign-in and one real assistant reply on BOTH new platforms.
- Ubuntu22.04, Debian12 and physical ARM64 qualification before broad support claims.
- Native Windows GUI/MSI/EXE and native Windows-app session discovery are separate
  future work, not features already implemented by this ZIP.
