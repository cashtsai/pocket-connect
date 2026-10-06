# Bridge (bundled runtime)

This directory is the bridge runtime that ships inside Pocket.app. The Pocket
desktop app uses it to set up a local, per-user bridge the first time it
detects your Mac has no bridge installed — you normally never need to touch
these files by hand.

## What the bridge does

The bridge is a small Python HTTP service that runs on **your** Mac and exposes
the agents already living there — Hermes personas, Claude Code, Codex — to the
Pocket iOS app over an authenticated local API. Your phone is a thin remote:
all credentials, sessions and heavy lifting stay on the desktop. Nothing is
relayed through third-party servers.

## How it gets installed

When Pocket.app's environment check finds no bridge, it runs
`deploy/install-local-bridge.sh` from this directory. That script:

- installs the bridge under `~/Library/Application Support/PocketConnect`
- creates a launchd agent labelled `com.pocketconnect.bridge`
- generates a fresh random `BRIDGE_TOKEN` for your install

Requirements: macOS 13+ and Python 3.10+ (the installer checks and explains
what is missing instead of failing silently).

## Configuration

Runtime configuration is environment-driven — see `.env.example` for the knobs
(bridge token, port, optional Telegram mirroring). Personas are whatever your
own Hermes/OpenClaw setup provides; the bridge has no built-in accounts.

## More

- Website & FAQ: https://pocket.shan.house
- Install FAQ: see `docs/INSTALL_FAQ.md` in the pocket-connect repository
