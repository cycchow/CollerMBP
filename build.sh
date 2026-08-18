#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "CoolerMBP must be built on macOS." >&2
  exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
DIST="$PWD/dist"
APP="$DIST/CoolerMBP.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/CoolerApp" "$APP/Contents/MacOS/CoolerApp"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/CoolerDaemon" "$DIST/CoolerDaemon"
cp "$BIN_DIR/coolermbpctl" "$DIST/coolermbpctl"
cp "$BIN_DIR/coolermbpsmc" "$DIST/coolermbpsmc"
cp Support/com.superstring.CoolerMBP.daemon.plist "$DIST/"

# Ad-hoc signing is sufficient for local installation. Developer-ID signing/notarization
# should be added before distributing a prebuilt binary to other Macs.
codesign --force --deep --options runtime --sign - "$APP"
codesign --force --options runtime --sign - "$DIST/CoolerDaemon"
codesign --force --options runtime --sign - "$DIST/coolermbpctl"
codesign --force --options runtime --sign - "$DIST/coolermbpsmc"

echo "Built: $APP"
