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
# Stop the old writer before invoking this build's recovery command. The new
# command has ownership-aware Ftst behavior and aborts when the old state is
# active but cannot be attributed safely.
if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo launchctl bootout "system/$LABEL"
fi
sudo dist/coolermbpsmc auto || {
  echo "Recovery could not verify Apple Automatic. Existing files and recovery metadata were preserved." >&2
  echo "Inspect with: sudo dist/coolermbpsmc status. If active Ftst ownership is unknown, review before using dist/coolermbpsmc recover-unknown-ftst." >&2
  exit 1
}
sudo install -o root -g wheel -m 755 dist/CoolerDaemon "$HELPER"
sudo install -o root -g wheel -m 644 dist/com.superstring.CoolerMBP.daemon.plist "$PLIST"
sudo install -o root -g wheel -m 750 dist/coolermbpctl /usr/local/bin/coolermbpctl
sudo mkdir -p /usr/local/sbin
sudo install -o root -g wheel -m 755 dist/coolermbpsmc /usr/local/sbin/coolermbpsmc

sudo launchctl bootstrap system "$PLIST"
sudo launchctl enable "system/$LABEL"
sudo launchctl kickstart -k "system/$LABEL"

sudo rm -rf /Applications/CoolerMBP.app
sudo ditto dist/CoolerMBP.app /Applications/CoolerMBP.app
sudo chown -R root:wheel /Applications/CoolerMBP.app
sudo chmod -R go-w /Applications/CoolerMBP.app

sleep 1
sudo /usr/local/bin/coolermbpctl ping || {
  echo "Daemon XPC handshake failed. Startup/authorization diagnostics:" >&2
  sudo tail -30 /var/log/CoolerMBP.log
  exit 1
}
sudo /usr/local/bin/coolermbpctl auto || {
  echo "Daemon answered ping, but Apple Automatic mode failed. Diagnostics:" >&2
  sudo tail -30 /var/log/CoolerMBP.log
  exit 1
}
sudo /usr/local/bin/coolermbpctl status || {
  echo
  echo "Daemon did not answer. Check: sudo launchctl print system/$LABEL" >&2
  echo "Emergency Apple-auto command: sudo /usr/local/sbin/coolermbpsmc auto" >&2
  sudo tail -30 /var/log/CoolerMBP.log
  exit 1
}

open /Applications/CoolerMBP.app
echo "CoolerMBP installed. Default mode: Apple Automatic"
