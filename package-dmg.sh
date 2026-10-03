#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# A distributable image supports both Apple Silicon and Intel by default.
TRIKI_ARCHS="${TRIKI_ARCHS:-arm64 x86_64}" ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'build/Triki Remote.app/Contents/Info.plist')
case "$VERSION" in *[!0-9.]*|'') printf 'Invalid app version\n' >&2; exit 1 ;; esac
STAGING="$(mktemp -d "$PWD/build/.dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/contents"
/usr/bin/ditto 'build/Triki Remote.app' "$STAGING/contents/Triki Remote.app"
ln -s /Applications "$STAGING/contents/Applications"
cp THIRD_PARTY_NOTICES.md "$STAGING/contents/Third-party notices.txt"
cp LICENSE "$STAGING/contents/License.txt"
cat > "$STAGING/contents/Read me first.txt" <<'EOF'
Triki Remote — macOS 13 or later

1. Quit any running copy of Triki Remote from its menu-bar menu.
2. Drag Triki Remote.app onto the Applications folder in this disk image.
3. Eject this disk image, then open Triki Remote from Applications.
4. Allow Bluetooth, Accessibility and Notifications when prompted.
   Accessibility: System Settings > Privacy & Security > Accessibility.
   Select /Applications/Triki Remote.app.
5. Wake your TRIKI and disconnect it from other apps/phones.

Media mode: press for Play/Pause, rotate for volume.
Double press: switch Media / Work mode.
Work mode: creates a Google Meet in Chrome. Sign in to Google first.
Allow Automation > Google Chrome to copy meeting links automatically.

If moving from ~/Applications, remove the old copy after quitting it.
If media controls stop after updating, remove the old Accessibility entry
and add /Applications/Triki Remote.app again.

This local build is not notarized unless its distributor has completed
Apple signing and notarization. macOS may block downloaded local builds.
Only if you trust the source, use System Settings > Privacy & Security
to review the blocked app and choose Open Anyway when available.
Do not disable Gatekeeper system-wide.

Source and licensing information:
https://github.com/dnk2000/triki-remote
EOF
codesign --verify --strict "$STAGING/contents/Triki Remote.app"
/usr/bin/hdiutil create -volname 'Triki Remote' -srcfolder "$STAGING/contents" \
  -format UDZO -ov "$STAGING/Triki Remote.dmg"
/usr/bin/hdiutil verify "$STAGING/Triki Remote.dmg"
OUTPUT="$PWD/build/Triki-Remote-$VERSION.dmg"
mv -f "$STAGING/Triki Remote.dmg" "$OUTPUT"
printf 'Created %s\n' "$OUTPUT"
