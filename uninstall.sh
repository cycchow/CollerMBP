#!/bin/bash
set -euo pipefail
LABEL="com.superstring.CoolerMBP.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# Restore Apple thermal control before removing anything.
if [[ -x /usr/local/sbin/coolermbpsmc ]]; then
  sudo /usr/local/sbin/coolermbpsmc auto
fi

pkill -x CoolerApp 2>/dev/null || true
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo rm -f "/Library/PrivilegedHelperTools/$LABEL" "$PLIST"
sudo rm -f /usr/local/bin/coolermbpctl /usr/local/sbin/coolermbpsmc
sudo rm -rf /Applications/CoolerMBP.app "/Library/Application Support/CoolerMBP"
echo "CoolerMBP removed; fan control returned to macOS."
