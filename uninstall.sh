#!/bin/bash
set -euo pipefail
LABEL="com.superstring.CoolerMBP.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

if [[ ! -x /usr/local/sbin/coolermbpsmc ]]; then
  echo "Cannot verify Apple Automatic: recovery tool is missing; preserving CoolerMBP files and metadata." >&2
  exit 1
fi

# Ask the daemon to restore control, then stop it and verify through the
# daemon-independent recovery tool before deleting its metadata.
if [[ -x /usr/local/bin/coolermbpctl ]]; then
  sudo /usr/local/bin/coolermbpctl auto
fi
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
sudo /usr/local/sbin/coolermbpsmc auto

pkill -x CoolerApp 2>/dev/null || true
sudo rm -f "/Library/PrivilegedHelperTools/$LABEL" "$PLIST"
sudo rm -f /usr/local/bin/coolermbpctl /usr/local/sbin/coolermbpsmc
sudo rm -rf /Applications/CoolerMBP.app "/Library/Application Support/CoolerMBP"
echo "CoolerMBP removed; fan control returned to macOS."
