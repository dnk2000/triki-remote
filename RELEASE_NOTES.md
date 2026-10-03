# Triki Remote 1.0 — preview

Native macOS menu-bar remote for TRIKI CAP001. Requires macOS 13 or later;
the DMG supports Apple Silicon and Intel.

- Media mode: press for global Play/Pause, rotate for system volume.
- Work mode: create a Google Meet in Chrome, with optional link copying.
- Double press to switch modes; notifications confirm mode changes and copies.
- Automatic BLE reconnection and saved settings.

## Install

Download `Triki-Remote-1.0.dmg`, quit any running copy, open the image, and drag
Triki Remote into Applications. Eject the image and launch from Applications.
Remove any older copy from `~/Applications` to avoid duplicate installations.
Allow Bluetooth, Accessibility and Notifications. Allow Automation for Chrome
if using automatic Meet link copying; sign in to Google in Chrome first.

**This preview uses ad-hoc signing and is not notarized by Apple.** macOS may
block a downloaded copy. If you trust the source, review the app in System
Settings → Privacy & Security → Open Anyway, when available. See
[Apple's instructions](https://support.apple.com/en-us/102445).
Do not disable Gatekeeper system-wide. Source builds are also supported.
After updates, Accessibility may require removing the old entry and adding
`/Applications/Triki Remote.app` again.

Tests, Xcode compilation, universal compilation and DMG integrity checks run
before publication. Physical-controller behavior and browser changes still
require manual testing; this is a preview, not a certified production release.

New source code is MIT licensed. Upstream notices are included in the DMG.
The icon and third-party marks are excluded from the new source-code license;
see the repository README for provenance and scope.
