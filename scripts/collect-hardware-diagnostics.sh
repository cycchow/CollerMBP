#!/bin/bash
set -u

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This collector requires macOS." >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo so daemon and SMC status can be read: sudo $0 [output-directory]" >&2
  exit 1
fi

LABEL="com.superstring.CoolerMBP.daemon"
LOG="/var/log/CoolerMBP.log"
APP="/Applications/CoolerMBP.app"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
CLI="/usr/local/bin/coolermbpctl"
SMC="/usr/local/sbin/coolermbpsmc"
SUPPORT="/Library/Application Support/CoolerMBP"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
OUT="${1:-/tmp/CoolerMBP-validation-${HOST}-${STAMP}}"

if ! mkdir -m 700 "$OUT"; then
  echo "Cannot create output directory (it may already exist): $OUT" >&2
  exit 1
fi
REPORT="$OUT/report.txt"
exec > >(tee "$REPORT") 2>&1

echo "CoolerMBP read-only hardware diagnostic collection"
echo "collection_utc=$STAMP"
echo "host=$HOST"
echo "output_directory=$OUT"
echo "NOTE: this script writes only its output files; it does not change SMC state."
echo

capture() {
  local name="$1"
  shift
  echo "===== $name ====="
  printf 'command:'
  printf ' %q' "$@"
  echo
  "$@" >"$OUT/$name.stdout" 2>"$OUT/$name.stderr"
  local result=$?
  echo "exit_status=$result"
  cat "$OUT/$name.stdout"
  if [[ -s "$OUT/$name.stderr" ]]; then
    echo "stderr:"
    cat "$OUT/$name.stderr"
  fi
  echo
}

capture sw_vers sw_vers
capture hardware_model sysctl -n hw.model
capture chip sysctl -n machdep.cpu.brand_string
capture logical_cpu_count sysctl -n hw.ncpu
capture performance_cpu_count sysctl -n hw.perflevel0.physicalcpu
capture efficiency_cpu_count sysctl -n hw.perflevel1.physicalcpu
capture uname uname -a
capture daemon_status "$CLI" status
capture standalone_smc_status "$SMC" status
capture launchd_service launchctl print "system/$LABEL"

echo "===== installed_identity ====="
for path in "$APP/Contents/Info.plist" "$HELPER" "/Library/LaunchDaemons/$LABEL.plist" "$CLI" "$SMC"; do
  if [[ -e "$path" ]]; then
    ls -lT "$path"
    shasum -a 256 "$path" 2>&1
  else
    echo "missing=$path"
  fi
done
if [[ -r "$APP/Contents/Info.plist" ]]; then
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>&1 || true
fi
echo "source_checkout=$PWD"
if git -C "$PWD" -c "safe.directory=$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
  git -C "$PWD" -c "safe.directory=$PWD" rev-parse HEAD
  git -C "$PWD" -c "safe.directory=$PWD" status --short
else
  echo "source_commit=unavailable (run from the CoolerMBP source checkout to record it)"
fi
echo

for name in config.json recovery.json fan-recovery.json; do
  path="$SUPPORT/$name"
  echo "===== state_file_$name ====="
  if [[ -r "$path" ]]; then
    cp -p "$path" "$OUT/$name"
    cat "$OUT/$name"
  else
    echo "missing_or_unreadable=$path"
  fi
  echo
done

echo "===== daemon_log ====="
if [[ -r "$LOG" ]]; then
  cp -p "$LOG" "$OUT/CoolerMBP.log"
  tail -n 300 "$LOG"
  echo "Full log copied to $OUT/CoolerMBP.log"
else
  echo "missing_or_unreadable=$LOG"
fi
echo
echo "Collection complete. Files are in $OUT"
