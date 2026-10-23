# Pocket Connect

**English** · [繁體中文](README.zh-Hant.md)

The desktop half of [Pocket](https://pocket.shan.house). Install it on the Mac where
your agents already run — Claude Code, Codex, Hermes personas — and your phone pairs
by scanning one QR code. No addresses to type, no tokens to paste.

It hosts a local bridge, opens an outbound tunnel so the phone can reach you from
anywhere, and hands the phone a pairing QR.

## What's here

| | |
|---|---|
| **`mac-app/`** | The menu-bar app (SwiftPM, no Dock icon). Environment check and one-click bridge install, Apple sign-in, pairing QR, device list, connection settings. Packages into a signed `.dmg`. This is the product. |
| **`relay/`** | Reference material for running your own fixed address instead of the built-in temporary tunnel. Optional. |

## Install

1. Download the latest `Pocket-<version>.dmg` from
   [Releases](https://github.com/cashtsai/pocket-connect/releases)
   (verify with the bundled `.sha256` if you like).
2. Open it and drag **Pocket** into **Applications**.
3. Launch it — a pocket icon appears in the menu bar. There is no Dock icon.

Releases are **Developer ID signed, notarized, and stapled — both the app and the
disk image**, so they install on any Mac, including offline or behind a network that
blocks Apple's notary service.

> Before v0.8.0 only the disk image carried a ticket, so the app itself could still
> trip Gatekeeper on first launch without network. Fixed; `packaging/build_dmg.sh`
> now refuses to finish if either ticket is missing.

**You also need**, and Pocket will not install these for you:

- **Python 3.10+** — macOS ships 3.9, which cannot run the bridge. `brew install python`.
- **Claude Code and/or Codex**, installed and signed in. Pocket reads their login
  state; it never touches their credentials.

Full walkthrough, why free mode asks for iCloud, pairing, and troubleshooting:
**[`docs/INSTALL_FAQ.md`](docs/INSTALL_FAQ.md)**.
End-user questions about the phone app live in the
[FAQ on the website](https://pocket.shan.house/#faq).

## Connecting

Two ways to reach your Mac from the phone:

- **Free, zero-config** — the desktop opens a temporary Cloudflare tunnel and restarts
  it automatically if it drops. The address changes each time, so you scan a fresh QR
  after a restart.
- **Your own fixed address** — put a Tailscale address or your own reverse proxy into
  Connection Settings. The address never changes, and free mode's iCloud requirement
  no longer applies.

There is also a **login-free pairing page** served by the bridge itself — the installer
prints the full link at the end of its output. That path needs neither an Apple sign-in
nor iCloud, and is the shortest way to pair.

## Developing

```bash
cd mac-app
swift build && swift test
swift run                            # menu-bar icon appears

./packaging/build_dmg.sh             # ad-hoc signed .dmg, for local testing
NOTARIZE=1 BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh   # the real thing
```

Releasing is **local, not CI**:

```bash
./packaging/cut_release.sh minor     # bump version, tag, push — then it tells you what's left
gh release create "vX.Y.Z" build/dist/Pocket-X.Y.Z.dmg build/dist/Pocket-X.Y.Z.dmg.sha256 ...
./packaging/verify_release.sh vX.Y.Z # verifies the asset people actually download
```

CI never touches release assets — it only runs tests and checks that a DMG can be
assembled. The reason is in `.github/workflows/release.yml`: CI cannot reach the
private bridge repo, so the DMG it builds has no bridge inside, and twice it raced a
real local build onto `releases/latest`.

**Always run `verify_release.sh` after uploading.** It downloads the published asset
and checks signature, notarization, both staple tickets, and the bundled payload — a
local build passing proves nothing about what got uploaded.

Structure and signing details: [`mac-app/README.md`](mac-app/README.md).

## Licence

**Apache License 2.0** (see [`LICENSE`](LICENSE)) — perpetual, royalty-free, with an
explicit patent grant. Fork it, modify it, ship it commercially; just keep the licence
and copyright notice.

A Tesla-style patent pledge is in [`PATENTS.md`](PATENTS.md): **use it in good faith
and we will not sue you over patents.** The brand is not covered — the *Pocket*
wordmark and pocket icon stay ours. Take the code, not the name.

> **Note on comments**: identifiers, APIs and docs are in English, but the explanatory
> comments in the source are in Traditional Chinese. They record specific incidents
> rather than restating the code, which is why they have not been stripped. If one
> blocks you, ask in an issue — translating a block on request is welcome.
