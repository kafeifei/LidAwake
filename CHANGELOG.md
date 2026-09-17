# Changelog

All notable changes to LidAwake are documented in this file.

## 0.2.3 - 2026-09-17

- Background update checks now download, install and relaunch on their own: `SUAutomaticallyUpdate` is on by default and the app takes over Sparkle's install-on-quit handler, running it as soon as the status menu is closed instead of waiting for a quit that a menu bar app rarely sees. The red dot and “有新版本 X.Y.Z…” item remain as the fallback when automatic install is off or not allowed, and a new “自动安装更新” menu item toggles it.

## 0.2.2 - 2026-09-17

- Scheduled Sparkle update checks no longer interrupt with a window: a new version now shows up as a red dot on the menu bar battery icon and a “有新版本 X.Y.Z…” menu item that opens Sparkle's usual update dialog when clicked; the dot clears once the update has been seen or the update session ends. Manual “检查更新…” is unchanged.
- `Scripts/release.sh` now signs only the archive built by the current run into `dist/appcast.xml`, by generating the appcast from a staging directory instead of scanning all of `dist/`; older archives left in `dist/` no longer add bogus appcast items or binary deltas.

## 0.2.1 - 2026-09-17

- Ship in-app updates through Sparkle 2.10: the app checks a GitHub Releases appcast once a day and offers a manual "检查更新…" menu item.
- Sleep the built-in display immediately (`pmset displaysleepnow`) when the lid closes while sleep is disabled and no external display is attached, instead of leaving the screen lit until the display sleep timer fires; the behavior needs the menu bar app to be running.

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
