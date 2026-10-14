#!/bin/bash
set -euo pipefail

LABEL="com.superstring.CoolerMBP.daemon"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CLI="/usr/local/bin/coolermbpctl"
SMC="/usr/local/sbin/coolermbpsmc"

if [[ -x "$CLI" ]] && sudo "$CLI" auto; then
  echo "Daemon verified Apple Automatic."
  exit 0
fi

if [[ ! -x "$SMC" ]]; then
  echo "Recovery tool is missing; no SMC changes were made." >&2
  exit 1
fi

echo "Daemon did not complete recovery. Requesting shutdown and waiting for its writer lock to be released."
sudo launchctl disable "system/$LABEL"
sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  if ! sudo launchctl print "system/$LABEL" >/dev/null 2>&1 && sudo "$SMC" lock-check >/dev/null 2>&1; then
    if sudo "$SMC" auto; then
      sudo launchctl enable "system/$LABEL"
      sudo launchctl bootstrap system "$PLIST"
      sudo launchctl kickstart -k "system/$LABEL"
      echo "Apple Automatic restored and verified; daemon restarted."
      exit 0
    fi
    echo "Standalone recovery failed. The daemon remains disabled and recovery metadata is preserved." >&2
    echo "Inspect with: sudo $SMC status. If another fan tool may own manual mode, do not override it." >&2
    echo "After stopping competing fan tools, explicit fan recovery is: sudo $SMC recover-unknown-fans" >&2
    echo "For unknown Ftst ownership use: sudo $SMC recover-unknown-ftst" >&2
    echo "Only when both unknown states are intentionally overridden use: sudo $SMC recover-unknown" >&2
    echo "After explicit recovery succeeds, rerun sudo /usr/local/sbin/coolermbp-recover to verify and restart the daemon." >&2
    exit 1
  fi
  sleep 0.25
done

echo "Timed out waiting for daemon shutdown and SMC writer-lock release. No standalone SMC write was attempted; recovery metadata is preserved." >&2
exit 1
