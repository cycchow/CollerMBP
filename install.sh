#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer only supports macOS." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This build is intended for Apple Silicon Macs." >&2
  exit 1
fi

./build.sh

LABEL="com.superstring.CoolerMBP.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
HELPER="/Library/PrivilegedHelperTools/$LABEL"

sudo mkdir -p /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 dist/CoolerDaemon "$HELPER"
sudo install -o root -g wheel -m 644 dist/com.superstring.CoolerMBP.daemon.plist "$PLIST"
sudo install -o root -g wheel -m 750 dist/coolermbpctl /usr/local/bin/coolermbpctl
sudo mkdir -p /usr/local/sbin
sudo install -o root -g wheel -m 755 dist/coolermbpsmc /usr/local/sbin/coolermbpsmc

sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST"
sudo launchctl enable "system/$LABEL"
sudo launchctl kickstart -k "system/$LABEL"

sudo rm -rf /Applications/CoolerMBP.app
sudo ditto dist/CoolerMBP.app /Applications/CoolerMBP.app
sudo chown -R root:wheel /Applications/CoolerMBP.app
sudo chmod -R go-w /Applications/CoolerMBP.app

sleep 1
sudo /usr/local/bin/coolermbpctl auto
sudo /usr/local/bin/coolermbpctl status || {
  echo
  echo "Daemon did not answer. Check: sudo launchctl print system/$LABEL" >&2
  echo "Emergency Apple-auto command: sudo /usr/local/sbin/coolermbpsmc auto" >&2
  exit 1
}

open /Applications/CoolerMBP.app
echo "CoolerMBP installed. Default mode: Apple Automatic"
