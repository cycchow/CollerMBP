# CoolerMBP hardware validation

This runbook prepares controlled validation on the M2 Pro and M3 Max. Hardware validation is **not complete** until the commands below have been run on each target and the report template is filled with captured output. No procedure here authorizes unattended SMC writes.

## Safety gate

- Read-only commands are marked **READ ONLY**. They do not request a mode change.
- Commands marked **SMC WRITE — explicit operator approval required** can alter fan mode/target or Ftst. Do not run one until the operator has reviewed the proposed command and approved that specific transition. The approval must precede execution.
- Never run `recover-unknown-ftst` as an automatic step. Do not run unknown-state recovery during this validation unless a human has reviewed the captured state and explicitly approves that specific override.
- Do not install/uninstall, stress the CPU/GPU, SIGKILL/crash the daemon, change curves, or alter SMC logic as part of the validation.
- At any stop condition below, stop transitions. Run only the read-only collector, preserve output, and report state. Do not continue to the next step or attempt guessed SMC writes.

## Commands and write classification

| Command | Classification | Purpose |
|---|---|---|
| `sudo coolermbpctl status` | READ ONLY | Daemon mode, persisted mode, fan readings, verification/recovery flags, Ftst and last error. |
| `sudo coolermbpsmc status` | READ ONLY | Direct SMC readings and Ftst diagnostics, independent of cached daemon status. |
| `sudo coolermbpctl ping` | READ ONLY | XPC availability only. |
| `sudo launchctl print system/com.superstring.CoolerMBP.daemon` | READ ONLY | Service state and process details. |
| `sudo tail -n 300 /var/log/CoolerMBP.log` | READ ONLY | Daemon events and errors. |
| `sudo scripts/collect-hardware-diagnostics.sh` | READ ONLY with respect to SMC | Captures status/log/state files to a timestamped directory. It writes only its output files. |
| `sudo coolermbpctl cool` / `auto` | SMC WRITE — explicit approval required | Enter Cool Surface / restore Apple Automatic. |
| `./install.sh` | SMC WRITE — explicit approval required | Upgrade: builds, requests Automatic, stops/replaces/starts daemon and app. |
| `sudo launchctl bootout ...` | May cause SMC writes | Graceful daemon termination invokes shutdown recovery. |
| `sudo /usr/local/sbin/coolermbp-recover` | SMC WRITE — explicit approval required | Daemon-first recovery; may run standalone Apple Automatic recovery. Never force unknown Ftst. |
| `sudo coolermbpsmc recover-unknown-ftst` | Explicit unknown-Ftst SMC WRITE | Overrides unknown ownership; excluded from automatic procedures. Requires separate human decision/approval. |

`coolermbpsmc status` reports `Ftst=available` or `unavailable` (or an uncertain read/format result), its value, ownership, the latest transition strategy, and recovery status. `strategy=notApplicable` before/after manual control is expected; `direct` and `ftstFallback` identify a successful manual path. Ftst availability alone does not prove it was written.

## Read-only collection

From this source checkout, run before and after each approved transition:

```bash
sudo scripts/collect-hardware-diagnostics.sh
```

The collector creates a private timestamped directory under `/tmp` by default. To select a destination:

```bash
sudo scripts/collect-hardware-diagnostics.sh /tmp/M2-Pro-before
```

It captures macOS version/build, model/chip/core counts, daemon and standalone SMC status, launchd state, installed binary hashes and app bundle version, source commit/dirty state when run from the checkout, config/recovery metadata, and the full daemon log plus its last 300 lines in `report.txt`. `requested mode` comes from the daemon; `persisted mode` is the saved daemon config. The installed binary hash identifies the installed files; a source commit does not prove that the installed binary was built from that commit.

If CoolerMBP is not installed, installed status commands will be recorded as missing/errors; the collector is still useful for model/build capture, but it cannot inspect fan/Ftst state without the installed read-only SMC utility. Do not build/install solely to make collection work without approval for the install's SMC effects.

## Shared preflight on each machine

1. Connect AC power; keep the Mac on a hard, unobstructed surface at a recorded ambient temperature. Close other fan-control utilities and do not start a stress workload.
2. Confirm the machine identity and topology against the target-specific section below. Record the exact `hw.model`, chip, `sw_vers -buildVersion`, and core counts; stop if the machine does not match.
3. Capture the preflight bundle. Then inspect both live status sources:

   ```bash
   sudo scripts/collect-hardware-diagnostics.sh
   sudo coolermbpctl ping
   sudo coolermbpctl status
   sudo coolermbpsmc status
   sudo launchctl print system/com.superstring.CoolerMBP.daemon
   ```

4. Do not start a transition unless `recoveryRequired=false`, `hardware verified=true`, all fan modes are readable as `auto` or `system`, the direct SMC and daemon readings agree, fan actual RPMs are plausible, and Ftst is either unavailable or readable as `0`/`inactive`. If Ftst is `1`, ownership is `unknown`, or any state is uncertain, stop and report.
5. Record all competing software and the current power/thermal conditions. Preserve each collector directory unchanged.

## M2 Pro procedure

Target: Apple M2 Pro, 8 P-cores + 4 E-cores, macOS 27.0.1. Ftst was previously reported unavailable; this validation must verify it on the actual machine rather than assume it.

1. Run shared preflight. Confirm chip/model/core counts and the exact OS build. Record `Ftst=unavailable` only if the collector reports it as unavailable; report other results literally.
2. If preflight passes, request approval for the Cool Surface write. After approval, run:

   ```bash
   sudo coolermbpctl cool
   ```

   Wait 25 seconds without adding load. Collect status and logs. Expected: `requested mode=coolSurface`, `persisted mode=coolSurface`, `hardware verified=true`, `recoveryRequired=false`, every fan `manual`, target RPMs within reported min/max, actual RPMs responding toward targets, and strategy `direct` unless a documented fallback was actually taken. If Ftst is unavailable, `ftstFallback` is not an acceptable result; stop if direct mode is rejected. Ftst should remain unavailable (not written).
3. If the Cool Surface state is normal, request separate approval to return to Apple Automatic. After approval, run:

   ```bash
   sudo coolermbpctl auto
   ```

   Collect status immediately and again after 25 seconds. Expected: daemon requested/persisted mode `appleAuto`, hardware verified, recovery not required, fan modes all `auto` or `system`, Ftst unavailable (or `0` if the read-only check instead found it available), and no CoolerMBP-owned Ftst state left active.
4. Follow the shared failure criteria. Do not repeat the manual transition on this machine if any criterion triggers.

## M3 Max procedure

Target: Apple M3 Max, 12 P-cores + 4 E-cores, macOS 26.6. Ftst availability is unknown until read from this machine.

1. Run shared preflight. Verify exact hardware and OS build. Record Ftst availability/value/ownership from the standalone SMC status; do not infer it from the M2 Pro.
2. If preflight passes, request approval for the Cool Surface write. After approval, run:

   ```bash
   sudo coolermbpctl cool
   ```

   Wait 25 seconds without added load, then collect status and logs. Expected: requested/persisted `coolSurface`, hardware verified, no recovery required, every fan `manual`, targets within reported limits, and actual RPMs responding. Strategy should be `direct` unless logs and status show the guarded `ftstFallback` path. If fallback occurs, it is acceptable only if Ftst was confirmed available/inactive beforehand, the CoolerMBP Ftst ownership metadata was written, status says `ownership=owned`, and readback is `Ftst=1`. Stop if an active unknown Ftst value appears or any part of that chain is missing.
3. If the manual state is normal, request separate approval to return to Apple Automatic. After approval, run:

   ```bash
   sudo coolermbpctl auto
   ```

   Capture status immediately and after 25 seconds. Expected: `appleAuto`, verified/no recovery, all fans `auto` or `system`, and Ftst either unchanged at `0` if unused, or verified `0` with ownership cleared if CoolerMBP owned it. If Ftst remains `1`, ownership is unknown, or readback is uncertain, stop; do not invoke unknown-Ftst recovery automatically.
4. Follow the shared failure criteria. Do not repeat the manual transition on this machine if any criterion triggers.

## Upgrade from an older installed version

This is a controlled, approval-gated upgrade, not part of the read-only preflight.

1. Before changing software, capture the installed version/hash, current status, config, both recovery records, and full log using the collector. Save the bundle outside the checkout.
2. Require a clean pre-upgrade state: no recovery required, verified status, no unknown/active Ftst, and all fans auto/system. Stop and report otherwise; do not install over unresolved state.
3. Close the app and stop other fan writers. Review `install.sh`. It builds first, gracefully boots out the existing daemon, runs the new standalone `auto` recovery, installs files, starts the daemon, then requests `auto` and verifies status. This can write fan mode/target and release an owned Ftst value.
4. Obtain explicit operator approval for the upgrade's SMC effects. Then run from the intended source checkout:

   ```bash
   ./install.sh
   ```

5. If it aborts, do not delete or replace recovery files. Capture a new diagnostic bundle and report whether the service is loaded; continue only after the failure state is reviewed.

## Returning to Apple Automatic and Ftst verification

The transition command is **SMC WRITE — explicit approval required**:

```bash
sudo coolermbpctl auto
sudo coolermbpctl status
sudo coolermbpsmc status
```

Success requires verified status, no recovery required, all fan modes `auto` or `system`, and Ftst absent or read back as `0`. When CoolerMBP used Ftst fallback, ownership must no longer be `owned`, and logs should include verified release. Do not treat a success message alone as sufficient; compare both status commands and retain the output.

## Graceful daemon restart

Restart only after a normal verified Apple Automatic state and explicit approval for a shutdown path that may write SMC state. Do not use `kill -9`, SIGKILL, or `launchctl kickstart -k`.

```bash
sudo coolermbpctl auto
sudo coolermbpctl status
sudo launchctl bootout system/com.superstring.CoolerMBP.daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.superstring.CoolerMBP.daemon.plist
sudo coolermbpctl ping
sudo coolermbpctl status
sudo coolermbpsmc status
```

`bootout` delivers a normal service stop; the daemon's shutdown handler attempts to restore Apple Automatic. If `bootout` or `bootstrap` fails, do not force-kill it; capture status/logs and stop.

## Failure criteria

Stop the transition sequence and report immediately if any of these occur:

- `recoveryRequired=true`, `hardware verified=false`, or status is stale/unavailable.
- Any fan mode is unknown, cannot be read, does not match the requested mode, or direct and daemon status disagree.
- An RPM is implausible, does not respond after 25 seconds, leaves reported limits, or fan noise/behavior is abnormal.
- Ftst is active unexpectedly, ownership is unknown, its format/read fails, or it remains active after a verified Auto request.
- Any AppleSMC communication/read/write error, transition timeout, or daemon error indicating failed verification/recovery.
- A fan-control app/process is discovered that was not stopped before testing.

On stop: do not issue another mode command, restart, install, or recovery command automatically. Capture a read-only bundle, preserve timestamps/logs, note current mode/RPM/Ftst fields, and report. A recovery action requires separate human review and explicit approval.

## Emergency recovery

First collect the current state if communication still works. The standard recovery helper can modify SMC state and is **not** a read-only diagnostic; run only after explicit operator approval and after other fan-control tools are stopped:

```bash
sudo /usr/local/sbin/coolermbp-recover
```

It tries daemon-supervised Apple Automatic first, then a lock-checked standalone restore. It does not authorize unknown fan or unknown Ftst ownership. If it fails, leaves the service disabled, or reports unknown ownership, stop and preserve metadata/logs. Do not run `recover-unknown-ftst` automatically. An unknown-Ftst override is a separate, potentially destructive decision and must not be folded into this procedure.

## Report template

Complete one copy per machine and per transition. Attach the immutable collector directories and include local wall-clock timezone plus UTC.

```text
Machine: [M2 Pro / M3 Max]
Date/time (local + timezone):
Date/time (UTC):
Operator / approval reference:
Ambient temperature / power source / surface:
Other fan-control tools stopped (names):

macOS version and build:
Hardware model / chip:
P-core / E-core counts:
CoolerMBP app version/build:
Installed daemon/CLI/SMC tool SHA-256:
Source checkout commit / dirty state:
Collector directory:

Transition: [preflight / Apple Automatic -> Cool Surface / Cool Surface -> Apple Automatic / restart / recovery]
Command and approval time:
Requested mode:
Persisted mode:
Hardware verified:
Recovery required:
Fan rows (index, mode/key, actual RPM, target RPM, min/max RPM):
Ftst availability:
Ftst actual value:
Ftst ownership:
SMC transition strategy:
Relevant daemon errors/log events:
Fan response/noise observations:
Stop criterion triggered? Which one?
Outcome / next action:
```

## Expected transition summary

| State | Daemon/persisted mode | Fan modes | Ftst | Verification |
|---|---|---|---|---|
| Preflight / Apple Automatic | `appleAuto` | `auto` or `system` | unavailable or `0`/inactive; no unknown active ownership | Verified; no recovery required |
| Cool Surface | `coolSurface` | all `manual` | Normally unchanged; if `ftstFallback` is actually used, `1` and owned until restore | Verified; targets in limits and RPM response observed |
| Return to Apple Automatic | `appleAuto` | `auto` or `system` | unavailable or verified `0`; CoolerMBP ownership cleared | Verified; no recovery required |

These are expected observations, not hardware claims. Report only what the target machine returned. A successful command run on one model does not validate the other.
