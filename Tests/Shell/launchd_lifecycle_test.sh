#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
N=0
ok() { N=$((N+1)); echo "ok $N - $1"; }
bad() { echo "not ok - $1" >&2; exit 1; }
has() { grep -Fq "$2" "$1" || bad "missing $2"; }
lacks() { ! grep -Fq "$2" "$1" || bad "unexpected $2"; }
before() { a="$(grep -nF "$2" "$1"|head -1|cut -d: -f1)"; b="$(grep -nF "$3" "$1"|head -1|cut -d: -f1)"; [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] || bad "order $2 before $3"; }
fixture() {
 NAME="$1"; initial="$2"; FIX="$TMP/$NAME"; BIN="$FIX/bin"; STATE="$FIX/state"; ROOT="$FIX/sys"; PROJ="$FIX/proj"
 mkdir -p "$BIN" "$STATE" "$ROOT/Library/Application Support/CoolerMBP" "$ROOT/var/log" "$PROJ"
 cp "$REPO/install.sh" "$REPO/recover.sh" "$PROJ/"
 echo "$initial" > "$STATE/service"; echo 0 > "$STATE/prints"; echo 0 > "$STATE/locks"; : > "$STATE/trace"
 cat > "$BIN/sudo" <<'MOCK'
#!/bin/bash
echo "sudo $*" >> "$MOCK_TRACE"; exec "$@"
MOCK
 cat > "$BIN/uname" <<'MOCK'
#!/bin/bash
case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) /usr/bin/uname "$@" ;; esac
MOCK
 cat > "$BIN/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
 cat > "$BIN/launchctl" <<'MOCK'
#!/bin/bash
echo "launchctl $*" >> "$MOCK_TRACE"
case "$1" in
 print)
  [[ "$(cat "$MOCK_STATE/service")" == loaded ]] || { echo 'Could not find service in domain' >&2; exit 113; }
  n="$(cat "$MOCK_STATE/prints")"; n=$((n+1)); echo "$n" > "$MOCK_STATE/prints"
  if [[ "$MOCK_PROCESS_NEVER" == 1 || ( "$MOCK_PROCESS_DELAY" -gt 0 && "$n" -le "$MOCK_PROCESS_DELAY" ) ]]; then echo 'state = waiting'; else echo 'state = running'; echo 'pid = 123'; fi ;;
 bootout) if [[ "$MOCK_BOOTOUT_STUCK" != 1 ]]; then echo unloaded > "$MOCK_STATE/service"; fi; echo 0 > "$MOCK_STATE/prints" ;;
 enable) : ;;
 bootstrap) [[ "$MOCK_BOOTSTRAP_FAIL" == 1 ]] && exit 1; echo loaded > "$MOCK_STATE/service"; echo 0 > "$MOCK_STATE/prints" ;;
 disable|kickstart) exit 91 ;;
 *) exit 92 ;;
esac
MOCK
 cat > "$BIN/cli" <<'MOCK'
#!/bin/bash
echo "cli $*" >> "$MOCK_TRACE"
case "$1" in
 auto) if [[ "$MOCK_DAEMON_AUTO_FAIL" == 1 ]]; then exit 1; fi ;;
 ping)
  n="$(cat "$MOCK_STATE/pings" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$MOCK_STATE/pings"
  [[ "$MOCK_PING_FAIL" == 1 ]] && exit 1
  [[ "$MOCK_PING_DELAY" -gt 0 && "$n" -le "$MOCK_PING_DELAY" ]] && exit 1
  echo pong ;;
 status)
  if [[ "$MOCK_DAEMON_BAD" == 1 ]]; then
   printf '%s\n' 'requested mode: maximum' 'persisted mode: appleAuto' 'hardware verified: false' 'hardware recovery required: true' 'verified fan-control: manual' 'SMC: Ftst=available:1, ownership=unknown'
  else
   printf '%s\n' 'requested mode: appleAuto' 'persisted mode: appleAuto' 'hardware verified: true' 'hardware recovery required: false' 'verified fan-control: auto, system' 'SMC: Ftst=available:0, ownership=inactive'
  fi ;;
 *) exit 2 ;;
esac
MOCK
 cat > "$BIN/smc" <<'MOCK'
#!/bin/bash
echo "smc $*" >> "$MOCK_TRACE"
case "$1" in
 lock-check)
  n="$(cat "$MOCK_STATE/locks")"; n=$((n+1)); echo "$n" > "$MOCK_STATE/locks"
  if [[ "$MOCK_LOCK_INIT_FAIL" == 1 ]]; then echo 'error: failed to initialize SMC connection' >&2; exit 1; fi
  if [[ "$n" -le "$MOCK_LOCK_DELAY" ]]; then echo 'error: Unable to acquire CoolerMBP SMC writer lock (errno 35)' >&2; exit 1; fi ;;
 auto)
  echo 'smc-auto' >> "$MOCK_TRACE"
  if [[ "$MOCK_CLEAR_METADATA" == 1 ]]; then rm -f "$COOLERMBP_INSTALL_ROOT/Library/Application Support/CoolerMBP/recovery.json" "$COOLERMBP_INSTALL_ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"; fi
  if [[ "$MOCK_SMC_AUTO_FAIL" == 1 ]]; then exit 1; fi ;;
 status)
  if [[ "$MOCK_SMC_BAD" == 1 ]]; then
   printf '%s\n' 'Ftst=available:1, ownership=unknown' 'fan 0: 400 rpm target=5000 range=1200-5000 mode=manual modeKey=F0md'
  else
   printf '%s\n' 'Ftst=available:0, ownership=inactive' 'fan 0: 2000 rpm target=2000 range=1200-5000 mode=auto modeKey=F0md' 'fan 1: 1800 rpm target=1800 range=1200-4800 mode=system modeKey=F1md'
  fi ;;
 *) exit 2 ;;
esac
MOCK
 cat > "$BIN/old-smc" <<'MOCK'
#!/bin/bash
echo "old-smc $*" >> "$MOCK_TRACE"
if [[ "$1" == lock-check ]]; then echo 'usage: coolermbpsmc [status|auto]' >&2; exit 2; fi
exec "$MOCK_BIN/smc" "$@"
MOCK
 cat > "$PROJ/build.sh" <<'MOCK'
#!/bin/bash
set -e
mkdir -p dist/CoolerMBP.app
cp "$MOCK_BIN/cli" dist/coolermbpctl
if [[ "$MOCK_NEW_SMC_MISSING" != 1 ]]; then cp "$MOCK_BIN/smc" dist/coolermbpsmc; fi
echo daemon > dist/CoolerDaemon; echo plist > dist/com.superstring.CoolerMBP.daemon.plist
chmod +x dist/coolermbpctl
if [[ -f dist/coolermbpsmc ]]; then
 if [[ "$MOCK_NEW_SMC_NOT_EXECUTABLE" == 1 ]]; then chmod -x dist/coolermbpsmc; else chmod +x dist/coolermbpsmc; fi
fi
MOCK
 cat > "$BIN/install" <<'MOCK'
#!/bin/bash
echo "install $*" >> "$MOCK_TRACE"
while [[ "$#" -gt 2 ]]; do shift; done
src="$1"; dest="$2"; mkdir -p "$(dirname "$dest")"; cp -R "$src" "$dest"
MOCK
 cat > "$BIN/ditto" <<'MOCK'
#!/bin/bash
echo "ditto $*" >> "$MOCK_TRACE"; mkdir -p "$(dirname "$2")"; cp -R "$1" "$2"
MOCK
 cat > "$BIN/chown" <<'MOCK'
#!/bin/bash
echo "chown $*" >> "$MOCK_TRACE"
MOCK
 cat > "$BIN/open" <<'MOCK'
#!/bin/bash
echo "open $*" >> "$MOCK_TRACE"
MOCK
 mkdir -p "$ROOT/usr/local/bin" "$ROOT/usr/local/sbin"
 cp "$BIN/cli" "$ROOT/usr/local/bin/coolermbpctl"
 cp "$BIN/old-smc" "$ROOT/usr/local/sbin/coolermbpsmc"
 chmod +x "$BIN"/* "$PROJ/build.sh"
 chmod +x "$ROOT/usr/local/bin/coolermbpctl" "$ROOT/usr/local/sbin/coolermbpsmc"
 export PATH="$BIN:$PATH" MOCK_TRACE="$STATE/trace" MOCK_STATE="$STATE" MOCK_BIN="$BIN"
 export COOLERMBP_INSTALL_ROOT="$ROOT" COOLERMBP_SUDO="$BIN/sudo" COOLERMBP_LAUNCHCTL="$BIN/launchctl"
 export COOLERMBP_READY_TIMEOUT_SECONDS=5 COOLERMBP_SHUTDOWN_TIMEOUT_SECONDS=5 COOLERMBP_POLL_INTERVAL_SECONDS=1
 export MOCK_PROCESS_NEVER=0 MOCK_PROCESS_DELAY=0 MOCK_PING_FAIL=0 MOCK_PING_DELAY=0 MOCK_DAEMON_BAD=0 MOCK_SMC_BAD=0 MOCK_DAEMON_AUTO_FAIL=0 MOCK_SMC_AUTO_FAIL=0 MOCK_LOCK_DELAY=0 MOCK_LOCK_INIT_FAIL=0 MOCK_BOOTSTRAP_FAIL=0 MOCK_BOOTOUT_STUCK=0 MOCK_CLEAR_METADATA=0 MOCK_NEW_SMC_MISSING=0 MOCK_NEW_SMC_NOT_EXECUTABLE=0 MOCK_INSTALL_FROM_OUTSIDE=0
}
run_install() { rc=0; if [[ "$MOCK_INSTALL_FROM_OUTSIDE" == 1 ]]; then (cd "$TMP" && "$PROJ/install.sh") > "$FIX/out" 2>&1 || rc=$?; else (cd "$PROJ" && ./install.sh) > "$FIX/out" 2>&1 || rc=$?; fi; echo "$rc" > "$FIX/rc"; }
run_recover() { rc=0; (cd "$PROJ" && ./recover.sh) > "$FIX/out" 2>&1 || rc=$?; echo "$rc" > "$FIX/rc"; }
succeeded() { [[ "$(cat "$FIX/rc")" == 0 ]] || { cat "$FIX/out"; bad "$1"; }; }
failed() { [[ "$(cat "$FIX/rc")" != 0 ]] || bad "$1"; }
seed_recovery() {
 mkdir -p "$ROOT/usr/local/bin" "$ROOT/usr/local/sbin"
 cp "$BIN/cli" "$ROOT/usr/local/bin/coolermbpctl"; cp "$BIN/smc" "$ROOT/usr/local/sbin/coolermbpsmc"
 chmod +x "$ROOT/usr/local/bin/coolermbpctl" "$ROOT/usr/local/sbin/coolermbpsmc"
}

# 1–5. Lifecycle ordering, bounded startup, XPC and hardware verification.
fixture install-delay loaded
export MOCK_PROCESS_DELAY=2 MOCK_PING_DELAY=2
echo old > "$ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"
run_install; succeeded 'delayed install should start'
before "$MOCK_TRACE" 'launchctl bootout' 'install -o root -g wheel -m 755 dist/CoolerDaemon'
before "$MOCK_TRACE" 'smc-auto' 'install -o root -g wheel -m 755 dist/CoolerDaemon'
before "$MOCK_TRACE" 'smc-auto' 'smc status'
before "$MOCK_TRACE" 'smc status' 'install -o root -g wheel -m 755 dist/CoolerDaemon'
before "$MOCK_TRACE" 'launchctl enable' 'launchctl bootstrap'
lacks "$MOCK_TRACE" 'kickstart -k'
[[ "$(grep -c '^launchctl bootstrap' "$MOCK_TRACE")" == 1 ]] || bad 'installer bootstrapped twice'
has "$FIX/out" 'service loaded, process running, XPC responding, Apple Automatic hardware verified'
ok 'installer shutdown/verification ordering, enable-before-single-bootstrap, delayed readiness'

fixture install-timeout unloaded
export MOCK_PROCESS_NEVER=1
run_install; failed 'installer timeout should fail'
has "$FIX/out" 'Startup readiness timed out'; has "$FIX/out" 'service state'
ok 'installer timeout returns failure and reports service state'

fixture install-xpc unloaded
export MOCK_PING_FAIL=1
run_install; failed 'XPC failure should fail'
has "$FIX/out" 'xpc=false'
ok 'installer reports XPC readiness failure'

fixture install-hardware unloaded
export MOCK_DAEMON_BAD=1 MOCK_CLEAR_METADATA=1
echo keep > "$ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"
run_install; failed 'hardware verification should fail'
has "$FIX/out" 'hardware=false'
snap="$(find "$ROOT/var/tmp" -name 'fan-recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == keep ]] || bad 'installer did not preserve pre-install metadata snapshot'
ok 'installer hardware verification failure is nonzero and metadata snapshot remains'

fixture install-lock loaded
export MOCK_LOCK_DELAY=99
run_install; failed 'writer lock timeout should fail'
before "$MOCK_TRACE" 'launchctl bootout' 'smc lock-check'
lacks "$MOCK_TRACE" 'smc-auto'
ok 'installer waits for shutdown and lock before restore or replacement'

# 13–18. Older-install compatibility, repository-built utility, and diagnostics.
fixture upgrade-old-version loaded
echo '{"mode":"appleAuto"}' > "$ROOT/Library/Application Support/CoolerMBP/config.json"
echo keep > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
printf '#!/bin/sh\necho old-cli\n' > "$ROOT/usr/local/bin/coolermbpctl"
printf '#!/bin/sh\necho old-smc\n' > "$ROOT/usr/local/sbin/coolermbpsmc"
chmod +x "$ROOT/usr/local/bin/coolermbpctl" "$ROOT/usr/local/sbin/coolermbpsmc"
export MOCK_INSTALL_FROM_OUTSIDE=1
run_install; succeeded 'upgrade from old utility should succeed'
before "$MOCK_TRACE" 'launchctl bootout' 'smc lock-check'
has "$MOCK_TRACE" 'smc lock-check'; lacks "$MOCK_TRACE" 'old-smc lock-check'
before "$MOCK_TRACE" 'smc-auto' 'install -o root -g wheel -m 755 dist/CoolerDaemon'
before "$MOCK_TRACE" 'launchctl enable' 'launchctl bootstrap'
[[ "$(grep -c '^launchctl bootstrap' "$MOCK_TRACE")" == 1 ]] || bad 'upgrade bootstrapped more than once'
lacks "$MOCK_TRACE" 'kickstart -k'
cmp -s "$PROJ/dist/coolermbpctl" "$ROOT/usr/local/bin/coolermbpctl" || bad 'old CLI was not replaced'
cmp -s "$PROJ/dist/coolermbpsmc" "$ROOT/usr/local/sbin/coolermbpsmc" || bad 'old SMC utility was not replaced'
has "$FIX/out" 'Readiness verified: service loaded, process running, XPC responding, Apple Automatic hardware verified.'
ok 'old-version upgrade uses new lock-check utility and verifies replacement and final state'

fixture install-new-smc-missing loaded
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
export MOCK_NEW_SMC_MISSING=1
run_install; failed 'missing new SMC utility should fail'
has "$FIX/out" 'new SMC utility is missing'; lacks "$MOCK_TRACE" 'launchctl bootout'
snap="$(find "$ROOT/var/tmp" -name 'recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'missing utility failure did not preserve recovery metadata'
ok 'missing new utility fails before daemon shutdown and preserves metadata'

fixture install-new-smc-not-executable loaded
export MOCK_NEW_SMC_NOT_EXECUTABLE=1
run_install; failed 'non-executable new SMC utility should fail'
has "$FIX/out" 'new SMC utility cannot execute'; lacks "$MOCK_TRACE" 'launchctl bootout'
ok 'non-executable new utility fails before daemon shutdown'

fixture install-contention loaded
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
export MOCK_LOCK_DELAY=99
run_install; failed 'actual writer lock contention should fail'
has "$FIX/out" 'could not acquire the writer lock'; lacks "$MOCK_TRACE" 'smc-auto'
snap="$(find "$ROOT/var/tmp" -name 'recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'lock contention failure did not preserve metadata'
ok 'actual writer lock contention is distinguished and fails safely'

fixture install-unload-timeout loaded
export MOCK_BOOTOUT_STUCK=1
run_install; failed 'daemon unload timeout should fail'
has "$FIX/out" 'old service still loaded'; lacks "$MOCK_TRACE" 'smc lock-check'
ok 'daemon unload timeout is reported separately from lock contention'

fixture install-smc-initialization-failure loaded
export MOCK_LOCK_INIT_FAIL=1
run_install; failed 'SMC initialization failure should fail'
has "$FIX/out" 'could not initialize or check the SMC writer lock'
ok 'SMC initialization failure is distinguished from writer lock contention'

# 6–9. Daemon-first recovery, verified fallback, failure preservation and lock.
fixture recover-daemon loaded
seed_recovery
echo original > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
run_recover; succeeded 'daemon-first recovery should succeed'
lacks "$MOCK_TRACE" 'launchctl bootout'; lacks "$MOCK_TRACE" 'launchctl bootstrap'
ok 'daemon-first recovery verifies without a needless restart'

fixture recover-daemon-bad loaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"
export MOCK_DAEMON_BAD=1
run_recover; failed 'daemon verification should fail'
has "$FIX/out" 'post-recovery verification failed'
lacks "$MOCK_TRACE" 'smc-auto'
snap="$(find "$ROOT/var/tmp" -name 'fan-recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'failure snapshot missing'
ok 'recovery rejects false daemon success and preserves metadata without retrying SMC'

fixture recover-fallback loaded
seed_recovery
export MOCK_DAEMON_AUTO_FAIL=1 MOCK_LOCK_DELAY=2
run_recover; succeeded 'standalone recovery fallback should succeed'
before "$MOCK_TRACE" 'launchctl bootout' 'smc lock-check'
before "$MOCK_TRACE" 'smc lock-check' 'smc-auto'
before "$MOCK_TRACE" 'launchctl enable' 'launchctl bootstrap'
lacks "$MOCK_TRACE" 'launchctl disable'; lacks "$MOCK_TRACE" 'kickstart -k'
[[ "$(grep -c '^launchctl bootstrap' "$MOCK_TRACE")" == 1 ]] || bad 'recovery bootstrapped twice'
ok 'fallback retains writer-lock coordination and clean launchd sequence'

fixture recover-split-state unloaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
export MOCK_DAEMON_AUTO_FAIL=1 MOCK_SMC_BAD=1
run_recover; failed 'direct hardware mismatch should fail'
has "$FIX/out" 'standalone status did not verify all fans automatic'
lacks "$MOCK_TRACE" 'launchctl bootstrap'
snap="$(find "$ROOT/var/tmp" -name 'recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'direct-state mismatch metadata snapshot missing'
ok 'recovery rejects direct SMC mismatch and retains pre-recovery metadata'

fixture recover-bootstrap-fail unloaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"
export MOCK_DAEMON_AUTO_FAIL=1 MOCK_BOOTSTRAP_FAIL=1
run_recover; failed 'bootstrap failure should fail'
has "$FIX/out" 'launchd bootstrap failed'
has "$FIX/out" 'Could not find service'
snap="$(find "$ROOT/var/tmp" -name 'fan-recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'bootstrap failure metadata snapshot missing'
ok 'recovery bootstrap failure returns nonzero and preserves metadata'

fixture recover-timeout loaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
export MOCK_DAEMON_AUTO_FAIL=1 MOCK_PING_FAIL=1
run_recover; failed 'recovery XPC timeout should fail'
has "$FIX/out" 'xpc=false'
snap="$(find "$ROOT/var/tmp" -name 'recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'recovery failure snapshot missing'
ok 'recovery timeout fails, reports XPC state, and preserves original metadata'

fixture recover-old-smc loaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/recovery.json"
cp "$BIN/old-smc" "$ROOT/usr/local/sbin/coolermbpsmc"
export MOCK_DAEMON_AUTO_FAIL=1
run_recover; failed 'recovery with unsupported installed utility should fail'
has "$FIX/out" 'installed SMC utility does not support lock-check'
snap="$(find "$ROOT/var/tmp" -name 'recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'unsupported installed utility did not preserve metadata'
ok 'recovery reports unsupported installed utility without retrying and preserves metadata'

fixture recover-missing-smc loaded
seed_recovery
echo preserve > "$ROOT/Library/Application Support/CoolerMBP/fan-recovery.json"
rm "$ROOT/usr/local/sbin/coolermbpsmc"
run_recover; failed 'recovery with missing installed utility should fail'
has "$FIX/out" 'installed SMC recovery utility is missing'
snap="$(find "$ROOT/var/tmp" -name 'fan-recovery.json.before' -print -quit)"
[[ -n "$snap" && "$(cat "$snap")" == preserve ]] || bad 'missing installed utility did not preserve metadata'
ok 'recovery reports missing installed utility and preserves metadata'

# 12. No unknown ownership recovery and no forced restart.
lacks "$REPO/install.sh" 'recover-unknown-fans'; lacks "$REPO/install.sh" 'recover-unknown-ftst'
lacks "$REPO/recover.sh" 'recover-unknown-fans'; lacks "$REPO/recover.sh" 'recover-unknown-ftst'
lacks "$REPO/install.sh" 'kickstart -k'; lacks "$REPO/recover.sh" 'kickstart -k'
ok 'helpers never invoke unknown-ownership recovery or forced restart'
echo "1..$N"

