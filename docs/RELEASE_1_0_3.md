# Pocket 1.0.3

This release keeps the 1.0.2 desktop app behavior and bundles a focused
OpenClaw notification-isolation fix on the November 25 maintained bridge
baseline `28ca8d1`. The patched bridge is
`a208fbaa0f9e2d72dafd6b90ff96bc3c7847458e`, also used by the verified live
hotfix. It excludes the newer Console report-reader feature.

## Privacy Fix

- Telegram, CLI and scheduled OpenClaw conversations no longer automatically
  send notifications to devices registered with the same Pocket bridge.
- Only exact session/run pairs issued by the bridge can send reply and approval
  notifications. Opening a session does not authorize future external turns.
- Notification preferences and hidden previews apply to OpenClaw pushes.
- Reconnect catch-up follows the same restriction. Unknown provenance, missing
  run IDs and pre-restart runs fail closed rather than exposing message text.

The change fixes unsolicited notifications. It is not a redesign of session
visibility or multi-user authorization, and does not change Telegram bindings.

## Existing Installations

The DMG contains the fixed bridge for new installations. Replacing the desktop
app alone does not guarantee that an already-running host bridge is updated:
the setup planner can reuse a healthy existing service. Existing hosts must
also update their bridge runtime, preserving their service configuration,
credentials and data, and restart that service. Managed/custom installations
must follow their host maintenance process rather than installing a second
bridge over the same port.

The notification ledger is process-local (24-hour TTL, 4096 aliases). During a
bridge update, old in-flight turns remain readable but do not generate a later
push unless their provenance is known to the new process.

## Verification

The fix passes the OpenClaw isolation, provider, resilience,
attachments/approvals, APNs registration and private-information guard suites.
Release CI must pass Swift tests, signing, notarization and DMG smoke checks.
Verify the downloaded DMG, not only a local build, before calling it published.
