# Changelog

All notable changes to LidAwake are documented in this file.

## 0.2.0 - 2026-09-17

- Add a time-boxed "keep awake with the lid closed on battery" session (30 minutes, 1 hour, or 2 hours) from the menu bar.
- End the battery session automatically on expiry, when the charge drops to 20%, or when stopped by hand; a session stopped by low battery does not resume after recharging.
- Bump the helper to version 5, so the app reinstalls the system helper on first launch.

## 0.1.0 - 2026-08-06

- Initial public release.
- Keep the Mac running with the lid closed while connected to AC power.
- Restore normal sleep on battery power, on errors, or when the policy is disabled.
- Start the system helper before login and reconcile power state every 10 seconds.
- Replace the system battery menu item with compact battery status and power telemetry.
- Read and set the native macOS charge limit when the system supports it.
- Add portable install and safe uninstall scripts, CI checks, and notarized release tooling.
