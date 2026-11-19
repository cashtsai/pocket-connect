# Ubuntu / Windows WSL2 platform preview handoff

## State

- Branch: `codex/connect-linux-windows`.
- Tested package source: `1a657ab1b26c133863430a659214bba42b2bb8b4`.
- Runtime revision: `54e089e653766dd847e23ff3f7b6ff4e79290f3f`.
- Package version: `1.0.2-preview.1`.
- Intended release tag: `platforms-v1.0.2-preview.1` (NOT a `v*` Mac tag).
- Public installer release: **pending explicit owner approval**. The publish
  attempt was blocked before execution because the bundles derive from private
  bridge source. Sanitization and tests do not replace disclosure approval.
- No production bridge restart, main-branch merge or stable Mac release change.
- Official website changes are prepared separately in the existing Lovable
  project. Do not deploy download URLs until the assets are actually public.

## Verification evidence

[CI run 44474152220](https://github.com/cashtsai/pocket-connect/actions/runs/44474152220)
is green for Ubuntu 24.04 x86_64 and Windows Server 2022.

- 12 unit tests: allowlist, integrity, unlisted-file/symlink rejection, private
  writes, systemd formatting, runtime environment, failed first-install retry,
  failed-upgrade runtime/config restoration, public-network sanitizer regression.
- Ubuntu: real DEB installation in an isolated normal user; real systemd unit;
  authenticated readiness; missing/wrong-token rejection; QR authorization gate;
  bundled Console; reinstall retains the pairing token.
- Windows: PowerShell 5.1 and 7 parsing plus mocked WSL2 preflight. WSL1, root and
  missing user systemd are rejected. No physical WSL installation was performed.
- Earlier ARM64 Ubuntu 24.04 container: real runtime/auth/reinstall smoke test
  passed. No user systemd, reboot or physical-phone test in that container.

Artifact checksums from the green CI run (all independently checked locally):

| File | SHA256 |
|---|---|
| `pocket-connect_1.0.2~preview.1_all.deb` | `45184496e1ba21e8ac40e7c3b494f5026f12a5550555a285a5e71896e5ca31dc` |
| `Pocket-Connect-1.0.2-preview.1-windows-wsl2.zip` | `b68ee782f126e4c5d12cb836670df42a35e8e4e722f8968d8b0e2bdf96088579` |
| `Pocket-Connect-1.0.2-preview.1-linux.tar.gz` | `7bfcdda4f570fe629cbee24d9ff84cefc49ae47fb728e3eaaa0f39dfc2a71c5e` |

## Implementation map

- `packaging/build_platforms.py`: tracked-file allowlist, private sanitizer,
  independent privacy verification, syntax checks, exact SHA manifest, tar/ZIP.
- `packaging/build_deb_from_archive.py`: payload verification, DEB launcher and
  desktop entries, approved Pocket icon, actual `dpkg-deb` build. No root service.
- `packaging/linux/pocket-connect`: per-user venv, staged installs, systemd,
  private credentials, explicit LAN opt-in, pairing/status/diagnostics/removal.
- `packaging/windows/Pocket-Connect.ps1`: existing WSL2 preflight, dependency
  confirmation, Linux setup, current-user startup shortcut and keepalive.
- `.github/workflows/build-platform-previews.yml`: pinned private runtime checkout
  with existing release credentials; sanitizer; build; isolated service test;
  Windows shell checks; artifact upload only. No public release automation.
- `packaging/README.md`: end-user setup, networking and limitations.

The privacy sanitizer originally rewrote the standard `100.64.0.0/10` CIDR and
broke bridge import. Only that exact public network constant is exempted now;
standalone/private host addresses remain blocked. Both sanitizer and verifier
are covered by regression tests. This source fix also applies to future Mac
builds, but the existing DMG has not been rebuilt as part of this task.

## Release after approval

1. Use only the artifact from green run `44474152220`, not older local builds.
   Download `pocket-connect-platform-previews` and verify its SHA256SUMS.
2. Publish a prerelease at the intended tag targeting the tested package commit,
   with `--latest=false`. Attach DEB, Linux tar, Windows ZIP and SHA256SUMS only.
   Never upload the raw private checkout or the private sanitizer table.
3. State WSL2, unsigned ZIP, explicit network setup and missing physical end-to-end
   tests clearly. Do not claim native Windows desktop session synchronization.
4. Download the public assets again and check size/hash. Confirm stable
   `releases/latest` still resolves to macOS v1.0.1.
5. Enable the prepared website's platform-specific URLs/labels/instructions,
   run bilingual/mobile browser QA, then deploy and inspect the live site.
6. Update this handoff and the root READMEs to replace pending-publication status.

## Acceptance still required

- Physical Windows 11 WSL2 install, ZIP unblock experience, sudo prompt,
  localhost browser launch, login startup and keepalive.
- Actual Linux/WSL provider sign-in and a real reply in Pocket. No provider
  credentials are installed or migrated by these packages.
- Phone on the same tailnet with Serve, QR claim, streaming, approval, reconnect.
- Ubuntu 22.04 / Debian 12 and physical ARM64 qualification before broad support
  claims. Current full service test is Ubuntu 24.04 x86_64.
- Real reboot/sleep/logout recovery and custom-port network routing.
- Native Windows GUI/MSI/EXE and native Windows-app session discovery are separate
  future work, not features hidden behind this ZIP.

Runtime rollback does not snapshot the database. Dependencies install from PyPI
at setup time, so this is not an offline, fully locked dependency distribution.
The default is localhost; no new public tunnel, firewall changes, provider login
or subscription is supplied. Stop/removal retains user history and tokens.
