#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

LABEL="com.superstring.CoolerMBP.daemon"
ROOT="${COOLERMBP_INSTALL_ROOT:-}"
SUDO="${COOLERMBP_SUDO:-sudo}"
LAUNCHCTL="${COOLERMBP_LAUNCHCTL:-launchctl}"
READY_TIMEOUT="${COOLERMBP_READY_TIMEOUT_SECONDS:-30}"
SHUTDOWN_TIMEOUT="${COOLERMBP_SHUTDOWN_TIMEOUT_SECONDS:-20}"
POLL_INTERVAL="${COOLERMBP_POLL_INTERVAL_SECONDS:-1}"
PLIST="$ROOT/Library/LaunchDaemons/$LABEL.plist"
HELPER="$ROOT/Library/PrivilegedHelperTools/$LABEL"
CLI="$ROOT/usr/local/bin/coolermbpctl"
SMC="$ROOT/usr/local/sbin/coolermbpsmc"
NEW_SMC="$REPO_ROOT/dist/coolermbpsmc"
RECOVER="$ROOT/usr/local/sbin/coolermbp-recover"
APP="$ROOT/Applications/CoolerMBP.app"
SUPPORT="$ROOT/Library/Application Support/CoolerMBP"
LOG="$ROOT/var/log/CoolerMBP.log"
SERVICE="system/$LABEL"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PRESERVE_DIR="$ROOT/var/tmp/CoolerMBP-install-$STAMP-$$"

sudo_run() { "$SUDO" "$@"; }
launchctl_run() { sudo_run "$LAUNCHCTL" "$@"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer only supports macOS." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This build is intended for Apple Silicon Macs." >&2
  exit 1
fi

service_output=""
service_rc=0
read_service() {
  service_rc=0
  service_output="$(launchctl_run print "$SERVICE" 2>&1)" || service_rc=$?
  return "$service_rc"
}
service_absent() {
  [[ "$service_rc" -ne 0 ]] &&
    printf '%s' "$service_output" | grep -Eqi 'could not find service|service .*not found|no such process'
}
fan_modes_are_automatic() {
  awk '
    /^fan [0-9]+:/ { count++; if ($0 !~ /mode=(auto|system)( |$)/) bad=1 }
    END { exit !(count > 0 && !bad) }
  '
}
ftst_is_inactive() {
  grep -Eq 'Ftst=unavailable(:unavailable)?, ownership=unavailable|Ftst=available:0, ownership=inactive'
}
verify_daemon_status() {
  local status="$1"
  printf '%s\n' "$status" | grep -Fqx 'requested mode: appleAuto' &&
    printf '%s\n' "$status" | grep -Fqx 'persisted mode: appleAuto' &&
    printf '%s\n' "$status" | grep -Fqx 'hardware verified: true' &&
    printf '%s\n' "$status" | grep -Fqx 'hardware recovery required: false' &&
    printf '%s\n' "$status" | grep -E '^verified fan-control: (auto|system)(, (auto|system))*$' >/dev/null &&
    printf '%s\n' "$status" | ftst_is_inactive
}
verify_standalone_status() {
  local status="$1"
  printf '%s\n' "$status" | fan_modes_are_automatic &&
    printf '%s\n' "$status" | ftst_is_inactive
}
show_failure_state() {
  sudo_run mkdir -m 700 -p "$PRESERVE_DIR" || true
  {
    echo "--- service state ---"
    service_rc=0
    if read_service; then
      echo "service_loaded=true"
      if printf '%s\n' "$service_output" | grep -Eq 'state = running|pid = [1-9][0-9]*'; then echo "process_running=true"; else echo "process_running=false"; fi
      printf '%s\n' "$service_output"
    elif service_absent; then
      echo "service_loaded=false process_running=false"
      printf '%s\n' "$service_output"
    else
      echo "service_loaded=unknown process_running=unknown"
      printf '%s\n' "$service_output"
    fi
    echo "--- daemon status ---"
    sudo_run "$CLI" status || true
    echo "--- direct SMC status ---"
    sudo_run "$SMC" status || true
    echo "--- recovery metadata (preserved in place) ---"
    sudo_run ls -lT "$SUPPORT/recovery.json" "$SUPPORT/fan-recovery.json" || true
    echo "--- daemon log ---"
    sudo_run tail -n 80 "$LOG" || true
  } 2>&1 | sudo_run tee "$PRESERVE_DIR/failure-report.txt" >&2
  if sudo_run test -f "$LOG"; then sudo_run cp -p "$LOG" "$PRESERVE_DIR/CoolerMBP.log" || true; fi
  local file
  for file in recovery.json fan-recovery.json; do
    if sudo_run test -f "$SUPPORT/$file"; then
      sudo_run cp -p "$SUPPORT/$file" "$PRESERVE_DIR/$file.after" || true
    fi
  done
  echo "Original recovery metadata snapshot and failure report: $PRESERVE_DIR" >&2
}
fail() {
  trap - ERR
  echo "Installation failed: $*" >&2
  show_failure_state
  echo "Existing recovery metadata was not removed. Review service and hardware state before retrying." >&2
  exit 1
}
on_error() {
  local code="$1" line="$2"
  trap - ERR
  echo "Installation command failed at line $line (exit $code)." >&2
  show_failure_state
  echo "Existing recovery metadata was not removed. Review service and hardware state before retrying." >&2
  exit "$code"
}
save_initial_metadata() {
  sudo_run mkdir -m 700 -p "$PRESERVE_DIR" || return 1
  local file
  for file in recovery.json fan-recovery.json; do
    if sudo_run test -f "$SUPPORT/$file"; then
      sudo_run cp -p "$SUPPORT/$file" "$PRESERVE_DIR/$file.before" || return 1
    fi
  done
  return 0
}
wait_for_shutdown_and_lock() {
  local attempt lock_output="" lock_kind="" unloaded=false
  for ((attempt = 0; attempt < SHUTDOWN_TIMEOUT; attempt++)); do
    service_rc=0
    read_service >/dev/null || true
    if service_absent; then
      unloaded=true
      if lock_output="$(sudo_run "$NEW_SMC" lock-check 2>&1)"; then return 0; fi
      if printf '%s\n' "$lock_output" | grep -Eqi 'usage:|unknown command|unrecognized command'; then
        fail "new SMC utility does not support lock-check: $lock_output"
      elif printf '%s\n' "$lock_output" | grep -Eqi 'Unable to acquire CoolerMBP SMC writer lock|writer lock.*unavailable'; then
        lock_kind="busy"
      else
        fail "new SMC utility could not initialize or check the SMC writer lock: $lock_output"
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
  if ! $unloaded; then
    fail "old service still loaded after ${SHUTDOWN_TIMEOUT}s: $service_output"
  fi
  case "$lock_kind" in
    busy) fail "new SMC utility could not acquire the writer lock after ${SHUTDOWN_TIMEOUT}s: $lock_output" ;;
    *) fail "new SMC utility could not verify the SMC writer lock" ;;
  esac
  return 1
}
wait_for_ready() {
  local attempt output loaded running ping status hardware standalone
  loaded=false
  running=false
  ping=false
  hardware=false
  for ((attempt = 0; attempt < READY_TIMEOUT; attempt++)); do
    loaded=false
    running=false
    ping=false
    hardware=false
    read_service || true
    output="$service_output"
    if [[ "$service_rc" -eq 0 ]]; then
      loaded=true
      if printf '%s\n' "$output" | grep -Eq 'state = running|pid = [1-9][0-9]*'; then running=true; fi
    fi
    if sudo_run "$CLI" ping >/dev/null 2>&1; then ping=true; fi
    status="$(sudo_run "$CLI" status 2>&1)" || true
    hardware=false
    if verify_daemon_status "$status"; then hardware=true; fi
    standalone="$(sudo_run "$SMC" status 2>&1)" || true
    if [[ "$loaded" == true && "$running" == true && "$ping" == true && "$hardware" == true ]] && verify_standalone_status "$standalone"; then
      echo "Readiness verified: service loaded, process running, XPC responding, Apple Automatic hardware verified."
      return 0
    fi
    if (( attempt + 1 < READY_TIMEOUT )); then sleep "$POLL_INTERVAL"; fi
  done
  echo "Startup readiness timed out after ${READY_TIMEOUT}s (loaded=$loaded running=$running xpc=$ping hardware=$hardware)." >&2
  return 1
}
trap 'on_error "$?" "$LINENO"' ERR

./build.sh
save_initial_metadata || fail "could not preserve the initial recovery metadata"
if [[ ! -f "$NEW_SMC" ]]; then
  fail "new SMC utility is missing: $NEW_SMC"
fi
if [[ ! -x "$NEW_SMC" ]]; then
  fail "new SMC utility cannot execute: $NEW_SMC"
fi

sudo_run mkdir -p "$ROOT/Library/PrivilegedHelperTools" "$ROOT/Library/LaunchDaemons" || fail "could not prepare system install directories"

service_rc=0
if read_service >/dev/null 2>&1; then
  echo "Stopping the previous daemon through launchd bootout."
  launchctl_run bootout "$SERVICE" || fail "could not request previous daemon shutdown"
else
  service_absent || fail "could not determine whether the previous service is loaded: $service_output"
  echo "No previous daemon is loaded."
fi

if ! wait_for_shutdown_and_lock; then
  fail "previous service did not terminate and release the SMC writer lock within ${SHUTDOWN_TIMEOUT}s"
fi
echo "Previous service is unloaded and the SMC writer lock is available."

echo "Requesting and verifying Apple Automatic once before replacing installed files."
sudo_run "$NEW_SMC" auto || fail "standalone Apple Automatic restoration failed"
standalone="$(sudo_run "$NEW_SMC" status 2>&1)" || fail "could not read standalone SMC status after restoration"
if ! verify_standalone_status "$standalone"; then
  echo "$standalone" >&2
  fail "standalone status did not verify all fans automatic and Ftst absent/inactive"
fi

sudo_run install -o root -g wheel -m 755 dist/CoolerDaemon "$HELPER" || fail "could not install daemon"
sudo_run install -o root -g wheel -m 644 dist/com.superstring.CoolerMBP.daemon.plist "$PLIST" || fail "could not install launchd plist"
sudo_run install -o root -g wheel -m 750 dist/coolermbpctl "$CLI" || fail "could not install CLI"
sudo_run mkdir -p "$ROOT/usr/local/sbin" || fail "could not prepare recovery-tool directory"
sudo_run install -o root -g wheel -m 755 dist/coolermbpsmc "$SMC" || fail "could not install standalone SMC tool"
sudo_run install -o root -g wheel -m 755 recover.sh "$RECOVER" || fail "could not install recovery helper"

sudo_run rm -rf "$APP" || fail "could not remove previous app bundle"
sudo_run ditto dist/CoolerMBP.app "$APP" || fail "could not copy app bundle"
sudo_run chown -R root:wheel "$APP" || fail "could not set app ownership"
sudo_run chmod -R go-w "$APP" || fail "could not secure app permissions"

launchctl_run enable "$SERVICE" || fail "could not enable daemon service"
launchctl_run bootstrap system "$PLIST" || fail "launchd bootstrap failed"
if ! wait_for_ready; then fail "daemon startup or Apple Automatic verification failed"; fi

open "$APP" || echo "Warning: daemon is verified, but the app could not be opened." >&2
sudo_run rm -rf "$PRESERVE_DIR"
echo "CoolerMBP installed and verified: Apple Automatic is active."
