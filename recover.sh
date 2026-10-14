#!/bin/bash
set -euo pipefail

LABEL="com.superstring.CoolerMBP.daemon"
ROOT="${COOLERMBP_INSTALL_ROOT:-}"
SUDO="${COOLERMBP_SUDO:-sudo}"
LAUNCHCTL="${COOLERMBP_LAUNCHCTL:-launchctl}"
READY_TIMEOUT="${COOLERMBP_READY_TIMEOUT_SECONDS:-30}"
SHUTDOWN_TIMEOUT="${COOLERMBP_SHUTDOWN_TIMEOUT_SECONDS:-20}"
POLL_INTERVAL="${COOLERMBP_POLL_INTERVAL_SECONDS:-1}"
PLIST="$ROOT/Library/LaunchDaemons/$LABEL.plist"
CLI="$ROOT/usr/local/bin/coolermbpctl"
SMC="$ROOT/usr/local/sbin/coolermbpsmc"
SUPPORT="$ROOT/Library/Application Support/CoolerMBP"
LOG="$ROOT/var/log/CoolerMBP.log"
SERVICE="system/$LABEL"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
PRESERVE_DIR="$ROOT/var/tmp/CoolerMBP-recovery-$STAMP-$$"

sudo_run() { "$SUDO" "$@"; }
launchctl_run() { sudo_run "$LAUNCHCTL" "$@"; }

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
wait_for_shutdown_and_lock() {
  local attempt
  for ((attempt = 0; attempt < SHUTDOWN_TIMEOUT; attempt++)); do
    read_service || true
    if service_absent && sudo_run "$SMC" lock-check >/dev/null 2>&1; then return 0; fi
    sleep "$POLL_INTERVAL"
  done
  return 1
}
wait_for_ready() {
  local attempt output loaded running ping hardware status standalone
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
cleanup_metadata_snapshot() {
  sudo_run rm -rf "$PRESERVE_DIR"
}
report_state() {
  {
    echo "--- launchd service state ---"
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
    echo "--- recovery metadata in place ---"
    sudo_run ls -lT "$SUPPORT/recovery.json" "$SUPPORT/fan-recovery.json" || true
    echo "--- daemon log ---"
    sudo_run tail -n 100 "$LOG" || true
  } 2>&1 | sudo_run tee "$PRESERVE_DIR/failure-report.txt" >&2
  if sudo_run test -r "$LOG"; then sudo_run cp -p "$LOG" "$PRESERVE_DIR/CoolerMBP.log" || true; fi
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
  echo "Recovery failed: $*" >&2
  report_state
  exit 1
}
on_error() {
  local code="$1" line="$2"
  trap - ERR
  echo "Recovery command failed at line $line (exit $code)." >&2
  report_state
  exit "$code"
}
trap 'on_error "$?" "$LINENO"' ERR

save_initial_metadata || fail "could not preserve the initial recovery metadata"
if [[ ! -x "$SMC" ]]; then
  fail "recovery tool is missing; no SMC changes were made"
fi

# Prefer the running daemon. A successful request is accepted only after the
# daemon and direct SMC status both verify the complete Apple Automatic state.
if [[ -x "$CLI" ]]; then
  if sudo_run "$CLI" auto; then
    if ! wait_for_ready; then fail "daemon recovery returned success but post-recovery verification failed"; fi
    cleanup_metadata_snapshot
    echo "Apple Automatic verified by daemon and direct SMC status."
    exit 0
  fi
  echo "Daemon-supervised recovery did not complete; using the lock-checked standalone path." >&2
fi

service_rc=0
if read_service; then
  echo "Requesting graceful daemon shutdown before standalone recovery."
  launchctl_run bootout "$SERVICE" || fail "could not request daemon shutdown"
else
  service_absent || fail "could not determine daemon state: $service_output"
  echo "Daemon is not loaded."
fi
if ! wait_for_shutdown_and_lock; then
  fail "daemon did not unload and release the SMC writer lock within ${SHUTDOWN_TIMEOUT}s"
fi

sudo_run "$SMC" auto || fail "standalone Apple Automatic restoration failed"
standalone="$(sudo_run "$SMC" status 2>&1)" || fail "could not read standalone status after restoration"
if ! verify_standalone_status "$standalone"; then
  echo "$standalone" >&2
  fail "standalone status did not verify all fans automatic and Ftst absent/inactive"
fi

launchctl_run enable "$SERVICE" || fail "could not enable daemon service"
launchctl_run bootstrap system "$PLIST" || fail "launchd bootstrap failed"
if ! wait_for_ready; then fail "daemon startup or post-recovery hardware verification failed"; fi

cleanup_metadata_snapshot
echo "Apple Automatic verified; daemon loaded, running, and responding."
