#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
INSTALL_PATH="$HOME/Applications/Triki Remote.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$HOME/Applications"
STAGING="$(mktemp -d "$HOME/Applications/.triki-install.XXXXXX")"
cleanup() {
  if [[ -d "$STAGING/Previous.app" && ! -e "$INSTALL_PATH" ]]; then mv "$STAGING/Previous.app" "$INSTALL_PATH"; fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
/usr/bin/ditto 'build/Triki Remote.app' "$STAGING/Triki Remote.app"
codesign --verify --strict "$STAGING/Triki Remote.app"
/usr/bin/killall 'Triki Remote' 2>/dev/null || true
for ((attempt=0; attempt<50; attempt++)); do
  if ! /usr/bin/pgrep -x 'Triki Remote' >/dev/null; then break; fi
  sleep 0.1
done
if /usr/bin/pgrep -x 'Triki Remote' >/dev/null; then
  printf 'Quit Triki Remote before installing. The installed app was not changed.\n' >&2
  exit 1
fi
if [[ -e "$INSTALL_PATH" ]]; then mv "$INSTALL_PATH" "$STAGING/Previous.app"; fi
mv "$STAGING/Triki Remote.app" "$INSTALL_PATH"
"$LSREGISTER" -u "$PWD/build/Triki Remote.app"
"$LSREGISTER" -f "$INSTALL_PATH"
open "$INSTALL_PATH"
printf 'Installed %s\n' "$INSTALL_PATH"
