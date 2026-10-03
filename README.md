# Triki Remote

Native macOS menu-bar app for the TRIKI CAP001 controller. Swift, AppKit, CoreBluetooth and UserNotifications; no third-party dependencies. Requires macOS 13 or later.

Repository: [dnk2000/triki-remote](https://github.com/dnk2000/triki-remote).

Downloads: [GitHub Releases](https://github.com/dnk2000/triki-remote/releases). Preview builds are ad-hoc signed and **not notarized by Apple**.

## Controls

- **Media mode:** single press = global Play/Pause; rotate = system volume. In Settings, **Reverse volume rotation** changes direction.
- **Work mode:** single press creates a Google Meet in Google Chrome. **Copy Meet link to clipboard** is enabled by default; turn it off to open meetings without touching the clipboard. A notification confirms successful copying.
- **Double press:** two presses within 350 ms toggle Media ↔ Work and show a notification. Single actions wait 350 ms so double presses cannot also pause media or create a meeting. Holding never repeats. Three presses produce a double followed by a single.

Modes can also be selected directly in the menu. Settings are saved automatically. Work settings hide media controls. The menu provides Settings, Accessibility permissions, connection status, and Quit.

## Build and install

### Install from a DMG

Open `Triki-Remote-1.0.dmg`, quit any running copy, and drag **Triki Remote.app** onto **Applications**. Eject the image and launch the app from `/Applications`. Grant the permissions described below. No developer tools are needed on the receiving Mac.

If you previously used `install.sh`, quit and remove the old `~/Applications/Triki Remote.app` copy to avoid launching the wrong version. Accessibility may need its old entry removed and the `/Applications` copy added again.

Create the DMG locally with Apple's Command Line Tools or Xcode:

```sh
./package-dmg.sh
```

The script builds for Apple Silicon and Intel, packages the app, an Applications shortcut, installation instructions and upstream notices, then verifies the compressed disk image. Output: `build/Triki-Remote-1.0.dmg`. Packaging does not install or launch the app. This local DMG is not notarized; packaging alone does not remove Gatekeeper warnings for downloaded apps. See Distribution status below for public releases.

### Install from source

Install Apple's Command Line Tools or Xcode, then:

```sh
git clone https://github.com/dnk2000/triki-remote.git
cd triki-remote
./test.sh
./install.sh
```

The installer builds and verifies the app, stops the running copy, replaces `~/Applications/Triki Remote.app`, registers it with macOS, and launches it. Staging prevents failed compilation/signing from replacing a working build. Future updates use the same command and bundle ID (`com.triki.remote`). Only one instance runs at a time.

Build without installing:

```sh
./build.sh
open "build/Triki Remote.app"
```

The default build targets the current architecture. For Apple Silicon and Intel:

```sh
TRIKI_ARCHS="arm64 x86_64" ./build.sh
```

Alternatively open `TrikiMediaButton.xcodeproj`, select the **TrikiMediaButton** scheme and **My Mac**, then Run. The internal target name is retained; the product is **Triki Remote.app**. Full Xcode is required for `xcodebuild`:

```sh
xcodebuild -project TrikiMediaButton.xcodeproj -scheme TrikiMediaButton \
  -configuration Release -derivedDataPath build/Xcode build
```

## Permissions

- **Bluetooth:** connects to TRIKI. Wake the controller and disconnect it from other apps/phones first.
- **Accessibility:** Media mode posts native system media-key down/up events. Allow Triki Remote under System Settings → Privacy & Security → Accessibility.
- **Automation → Google Chrome:** required only when automatic Meet link copying is enabled. The app creates a tab and reads that specific tab's URL through Apple's system `osascript` utility. No Chrome JavaScript permission or third-party automation app is needed.
- **Notifications:** mode changes, copied-link confirmation, and Meet errors. macOS Focus/settings may suppress banners; errors are also logged.

Sign in to Google in the Chrome profile that handles external links. Google handles account and camera/microphone prompts. Media mode follows macOS's active Now Playing session; some audio outputs do not support software volume. No Apple Music-specific control, media-library access, or Input Monitoring is used.

Local builds use ad-hoc signing. Rebuilding can require re-enabling macOS permissions. Preferences from the original `com.triki.media-button` identity are migrated once; permissions cannot be migrated by the app.

## Reliability and implementation

Four Swift files:

| File | Responsibility |
| --- | --- |
| `App.swift` | Menu, settings, preferences, notifications and lifecycle |
| `TrikiBluetoothManager.swift` | BLE connection, frame assembly, button gestures and rotation detection |
| `MediaKeyController.swift` | Native Play/Pause and volume key events |
| `MeetingController.swift` | Nonblocking Chrome automation, timeouts, cancellation and clipboard handling |

BLE connection/setup has a 20-second deadline. After initialization, no valid IMU frames within five seconds triggers reconnection. Failed connections retry after 2, 4, 8… seconds, capped at 30; receiving valid data resets the delay. Bluetooth power-on restarts scanning. Disconnects cancel pending button actions and incomplete frames but preserve the last button state, avoiding a repeat when reconnecting with a held button. A release and re-press entirely while disconnected cannot be observed.

Rotation requires two qualifying samples, rejects jitter/sideways motion, and sends at most one volume step per 180 ms. Incoming BLE bursts cannot produce a burst of volume-key events. Thresholds use raw gyro units because the device scale is undocumented.

Meet automation never blocks the UI/Bluetooth queue. Script calls time out (60 seconds for startup/permission, 10 seconds for URL reads); the app waits up to 90 seconds for a meeting URL. It tracks a tab by ID even when tabs/windows change. Only canonical HTTPS `meet.google.com/xxx-xxxx-xxx` links are copied, without account/query parameters. Sign-in pages and `/new` are never copied. Starting another meeting or disabling copying cancels the earlier pending copy; stale results cannot overwrite the clipboard. Turning copying back on applies to the next meeting. Quitting cancels outstanding work.

## Validation

```sh
./test.sh
```

Checks cover single/double/triple presses, long holds, invalid/chunked frames, button state across reconnects, rotation direction/jitter/rate limiting, media-key encoding, Meet URL validation, actual local AppleScript execution, errors, timeouts, cancellation, and main-queue responsiveness. Tests do not post media keys, create meetings, or modify the clipboard.

An existing two-press hardware capture can additionally be replayed:

```sh
./test.sh build/triki-diagnostic.log
```

That optional capture is local and ignored by Git. Temporary raw-packet logging and the temporary notification-test launch flag have been removed from the app.

Manual hardware checks remain necessary: connect/wake the cap; press/hold/release; double-press in both modes; rotate; power-cycle the cap and Mac Bluetooth; create Meet with copying on/off; cancel copying while a tab loads; verify notifications and denied-permission behavior. Automated checks do not certify radio reliability or Google's live website.

For logs, use Console.app filtered to `Triki Remote`, or quit the app and run:

```sh
"$HOME/Applications/Triki Remote.app/Contents/MacOS/Triki Remote"
```

## Protocol reference

The native Swift app was implemented separately using [TRIKI-Control](https://github.com/koksny/TRIKI-Control) by Wojciech "Koksny" Górny as a BLE protocol reference, at commit `8d1bdff17a419930f7a89c5244928b199d4e6ee3`. Its [MIT license](https://github.com/koksny/TRIKI-Control/blob/8d1bdff17a419930f7a89c5244928b199d4e6ee3/LICENSE) was inspected before implementation. The current app does not bundle the reference project's Python/Android application, architecture, or artwork. The reference supplied the service/characteristic UUIDs, initialization sequence, and packet-layout information below.

| Purpose | UUID |
| --- | --- |
| Nordic UART service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX initialization write | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX / IMU notifications | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

Subscribe to TX, wait for confirmation, then write `20 10 00 D0 07 34 00 03` to RX without response (~53 Hz). No additional handshake or keepalive is used by the reference sequence. See its [protocol notes](https://github.com/koksny/TRIKI-Control/blob/8d1bdff17a419930f7a89c5244928b199d4e6ee3/docs/protocol.md).

Frames are 14 bytes: `22`, button state `00/01`, six signed little-endian IMU channels. The reference calls the second byte a packet ID; this controller's captured press/release cycles confirmed the requested button mapping. Notifications can contain partial/multiple frames (observed 20/20/2-byte chunks), so assembly preserves frame order. Unsupported states `02…0F` are consumed as whole frames.

## Licensing, attribution, and branding

### Reference project and repository history

TRIKI-Control is copyright © 2026 Wojciech "Koksny" Górny and licensed under MIT. MIT permits use, modification, redistribution, sublicensing, and commercial sale, subject to its terms. When distributing copies or substantial portions of the covered software or documentation, preserve the copyright and permission notice; a link or acknowledgment alone does not replace that notice. MIT does not require publishing the source of separately written application code. See the [MIT license text](https://opensource.org/license/mit).

**This repository retains TRIKI-Control's Git history.** A separately implemented Swift app does not make that history independently authored. Distributing a clone with that history also distributes upstream materials, whose notices must remain intact. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) preserves the full upstream MIT notice and identifies its scope. Keep it with source distributions containing those materials, and include it with any binary distribution incorporating covered upstream code or assets. Do not remove license notices from historical upstream files.

The new Swift implementation, build scripts, tests, and documentation are copyright © 2026 Denys Iliasov and available under the [MIT license](LICENSE). Historical upstream materials retain their original copyright and license. The new code license excludes `AppIcon.png`, `TrikiRemote.icns`, and third-party trademarks; it does not grant reuse rights to those materials.

### Icon and third-party names

`AppIcon.png` is the editable high-resolution artwork source, generated with imagegen from the user's supplied silver TRIKI cap image. `TrikiRemote.icns` is the packaged 16–1024 px icon used by both build paths. The PNG is retained as a source asset, not bundled at runtime. This artwork was not taken from TRIKI-Control. On October 3, 2026, the maintainer confirmed permission to use the supplied image and branding for this application. This records the maintainer's confirmation, not an independent rights audit or a sublicense to downstream users. AI generation alone does not establish those permissions.

Triki Remote is an unofficial compatibility utility and is not affiliated with or endorsed by TRIKI-Control's author, Caps Apps, Żabka, Apple, or Google. Third-party product names and marks belong to their respective owners. Neither the upstream software license nor this acknowledgment grants rights to third-party logos or branding. Names and logos can raise trademark issues separately from copyright; see the [U.S. Copyright Office's explanation](https://www.copyright.gov/help/faq/faq-protect.html) for that distinction in U.S. law.

For redistribution or rebranding, obtain any needed permissions for the excluded artwork and marks or replace them with your own assets. This records provenance and known licensing limits, not a jurisdiction-specific legal clearance.

## Distribution status

GitHub Actions runs tests, checks the Xcode project, and packages a universal DMG on pushes to `main` and pull requests. Successful builds retain a DMG artifact for 14 days. Pushing a `triki-v*` tag runs the same checks and publishes a **prerelease** with the DMG and SHA-256 checksum; release notes come from `RELEASE_NOTES.md`. Failed builds do not publish a release. Actions are pinned to commit hashes and the publishing job alone receives repository write permission.

Local release builds enable Hardened Runtime and the Apple Events entitlement; compilation treats warnings as errors. The same settings apply in Xcode. This is a locally built application, **not a notarized public release**.

To prepare a distributable build, supply your own Developer ID Application identity:

```sh
TRIKI_ARCHS="arm64 x86_64" TRIKI_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" ./build.sh
```

Then notarize and staple the app using your Apple Developer credentials and complete the manual hardware checks above. See [Apple's notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). No signing identity, credentials, or notarization ticket is included in this repository.
