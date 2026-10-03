#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ModuleCache
STAGING="$(mktemp -d "$PWD/build/.package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP_PATH="$STAGING/Triki Remote.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHITECTURES="${TRIKI_ARCHS:-$(uname -m)}"
BINARIES=()
for ARCH in $ARCHITECTURES; do
  case "$ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;; esac
  BINARY="$STAGING/TrikiRemote-$ARCH"
  xcrun swiftc -swift-version 5 -O -warnings-as-errors -sdk "$SDK_PATH" -target "$ARCH-apple-macosx13.0" \
    -module-cache-path "$PWD/build/ModuleCache" TrikiMediaButton/*.swift -o "$BINARY"
  BINARIES+=("$BINARY")
done
xcrun lipo -create "${BINARIES[@]}" -output "$APP_PATH/Contents/MacOS/Triki Remote"
cp TrikiMediaButton/Info.plist "$APP_PATH/Contents/Info.plist"
cp TrikiMediaButton/TrikiRemote.icns "$APP_PATH/Contents/Resources/TrikiRemote.icns"
cp LICENSE "$APP_PATH/Contents/Resources/License.txt"
cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/Third-party notices.txt"
SIGN_IDENTITY="${TRIKI_SIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY" --options runtime --entitlements TrikiMediaButton/TrikiRemote.entitlements)
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_OPTIONS+=(--timestamp); fi
codesign "${SIGN_OPTIONS[@]}" "$APP_PATH"
codesign --verify --strict "$APP_PATH"
# Keep the last successful bundle intact until compilation and signing succeed.
if [[ -d 'build/Triki Remote.app' ]]; then mv 'build/Triki Remote.app' "$STAGING/Previous.app"; fi
if ! mv "$APP_PATH" 'build/Triki Remote.app'; then
  if [[ -d "$STAGING/Previous.app" ]]; then mv "$STAGING/Previous.app" 'build/Triki Remote.app'; fi
  exit 1
fi
printf 'Built %s/build/Triki Remote.app\n' "$PWD"
