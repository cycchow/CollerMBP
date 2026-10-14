# CoolerMBP hardware validation

This runbook prepares controlled validation on the M2 Pro and M3 Max. Hardware validation remains **unverified** until the procedures have actually been run on each target and captured in a report. No commands in this document are automated.

## Safety rules

- Read-only commands do not request a mode change. Any command that can change fan mode, fan target, or Ftst is marked **SMC WRITE — explicit operator approval required**. Get approval for each transition before running that command.
- Keep the operator present during manual mode. Do not run CatBoost, CPU/GPU stress workloads, artificial heating, or cooling-curve changes. Do not crash or SIGKILL the daemon.
- Do not invoke unknown-ownership recovery automatically. It is outside the normal validation sequence.
- If a stop criterion occurs, stop transitions. Collect read-only diagnostics, preserve the output, and report the observed state. Do not restart, install, or attempt recovery automatically.
- Installation/upgrade is permitted only in Phase 1, after safety review and explicit operator approval. It is never part of Phase 0 and is never automatic.

## Command classification

| Command | Classification | Notes |
|---|---|---|
| `sw_vers`, `sysctl`, `test -e`, `launchctl print`, `tail` | READ ONLY | System/hardware inventory and logs. |
| `sudo coolermbpctl status` | READ ONLY | Daemon state, requested/persisted mode, temperatures, fan readings and verification flags. |
| `sudo coolermbpsmc status` | READ ONLY | Direct fan and Ftst readings, ownership and latest transition strategy. |
| `sudo coolermbpctl ping` | READ ONLY | XPC reachability only. |
| `sudo scripts/collect-hardware-diagnostics.sh` | READ ONLY with respect to SMC | Writes a local diagnostic bundle only; it does not issue a mode/recovery command. |
| `sudo coolermbpctl cool` | SMC WRITE — explicit operator approval required | Persists Cool Surface. It may enter manual control if policy and thermal conditions require it. |
| `sudo coolermbpctl max` | SMC WRITE — explicit operator approval required | Requests deterministic maximum fan control and verifies all fans entered manual mode. |
| `sudo coolermbpctl auto` | SMC WRITE — separate explicit operator approval required | Requests Apple Automatic and verifies hardware readback. |
| `./install.sh` | INSTALL + SMC WRITE — explicit operator approval required | Builds, stops/replaces/starts services, requests Auto, and may restore fan/Ftst state. See the installer constraint below. |
| `sudo launchctl bootout ...` | May cause SMC writes | Graceful daemon shutdown calls its restoration handler. Restart only in Phase 6. |
| `sudo /usr/local/sbin/coolermbp-recover` | SMC WRITE — explicit operator approval required | Daemon-first Apple Automatic recovery; never treats unknown Ftst ownership as approved. |
| `coolermbpsmc recover-unknown-ftst` | Explicit unknown-Ftst SMC WRITE | Not part of the automated or normal validation procedure. Requires separate review and approval. |

`coolermbpsmc status` reports Ftst availability/value/ownership and the last SMC strategy. `direct` and `ftstFallback` identify the strategy used by a successful manual transition; `notApplicable` is expected before/after manual control. Availability by itself does not mean Ftst was written.

## PHASE 0 — Read-only machine inventory

No CoolerMBP installation is required. Run this before installation or upgrade. Record commands that are unavailable as unavailable; do not treat missing new status fields as either a pass or a failure.

```bash
sw_vers
sysctl -n hw.model
sysctl -n machdep.cpu.brand_string
sysctl -n hw.perflevel0.physicalcpu
sysctl -n hw.perflevel1.physicalcpu
for path in \
  /Applications/CoolerMBP.app \
  /Library/PrivilegedHelperTools/com.superstring.CoolerMBP.daemon \
  /Library/LaunchDaemons/com.superstring.CoolerMBP.daemon.plist \
  /usr/local/bin/coolermbpctl \
  /usr/local/sbin/coolermbpsmc \
  /usr/local/sbin/coolermbp-recover; do
  if [[ -e "$path" ]]; then echo "present: $path"; else echo "missing: $path"; fi
done
sudo scripts/collect-hardware-diagnostics.sh
```

The collector attempts installed daemon/SMC status and launchd inspection. If CoolerMBP is absent or an older version lacks those commands/fields, its report records the command errors or missing files. Use other already-available read-only evidence where possible. Do not infer fan/Ftst state from an unavailable field.

### Diagnostic bundle handling

The default directory is `/tmp/CoolerMBP-validation-${HOST}-${UTC_TIMESTAMP}`. The collector runs as root and creates the directory with mode `0700` (root-owned, accessible only to root). It writes `report.txt`, command stdout/stderr files, available config/recovery JSON, and a timestamp-preserving copy of `/var/log/CoolerMBP.log`.

Inspect locally:

```bash
sudo less /tmp/CoolerMBP-validation-HOST-TIMESTAMP/report.txt
sudo ls -laT /tmp/CoolerMBP-validation-HOST-TIMESTAMP
```

Replace the example directory with the actual path printed by the collector. Do not loosen permissions with `chmod 777`. Before retrieving the bundle as your regular user, copy it into a new private directory and take ownership:

```bash
mkdir -m 700 "$HOME/CoolerMBP-diagnostics"
sudo cp -R /tmp/CoolerMBP-validation-HOST-TIMESTAMP "$HOME/CoolerMBP-diagnostics/"
sudo chown -R "$(id -u):$(id -g)" "$HOME/CoolerMBP-diagnostics/CoolerMBP-validation-HOST-TIMESTAMP"
chmod -R go-rwx "$HOME/CoolerMBP-diagnostics/CoolerMBP-validation-HOST-TIMESTAMP"
```

Review and redact before sharing. The bundle may disclose local usernames and paths, process IDs, installed software and binary hashes, hardware details, daemon errors, and config/recovery records describing fan modes, targets, or Ftst ownership. Share only the reviewed/redacted copy through an approved secure channel; preserve the original locally for comparison.

A source commit SHA identifies source-tree history only. It does not establish that installed binaries were built from that checkout: the installed app/daemon/tools may be stale, locally modified, built from another tree, or replaced. The collector records installed hashes and app version separately, but those values do not create build provenance.

## PHASE 1 — Controlled installation or upgrade

1. Review Phase 0 evidence, identify any older installation, and use available read-only tools to assess current fan modes, actual/target RPM, Ftst value/ownership if exposed, daemon health, logs, and other fan-control software.
2. If the old installation cannot expose the new fields (`hardware verified`, `recovery required`, or Ftst ownership), record them as unavailable. Do not interpret that as failure or success. Require an explicit safety assessment from the available hardware evidence. If fan mode/Ftst state cannot be assessed sufficiently, defer installation and testing; do not guess.
3. Stop if read-only evidence shows unknown/active Ftst ownership, unexplained manual fan mode, SMC communication errors, abnormal fan behavior, or unresolved recovery. Preserve the Phase 0 bundle and review before any state-changing operation.
4. Review `install.sh` and record its effects: it builds first; may boot out the existing daemon; runs the new standalone `auto`; replaces the helper, tools and app; bootstraps/enables the daemon; then invokes `launchctl kickstart -k`, requests `auto`, and checks status. The `kickstart -k` force-restarts the service. **The current installer must not be run under a constraint that prohibits forced daemon termination.** That limitation must be resolved before this validation can use `./install.sh`; this documentation-only change does not alter the installer.
5. Once the installer path is compatible with the active safety constraints, obtain explicit operator approval for the specific installation/upgrade. Then run it manually from the reviewed source checkout:

   ```bash
   ./install.sh
   ```

   Do not trigger it from a collector, test script, or unattended sequence. If it aborts or partially installs, preserve `/var/log/CoolerMBP.log`, both recovery metadata files under `/Library/Application Support/CoolerMBP`, and the pre/post diagnostic bundles. Do not remove metadata or rerun the installer until the failure is reviewed.

## PHASE 2 — Post-installation baseline verification

After the operator has completed Phase 1, collect a new bundle and inspect both status sources:

```bash
sudo scripts/collect-hardware-diagnostics.sh
sudo coolermbpctl ping
sudo coolermbpctl status
sudo coolermbpsmc status
```

Require all of the following before any mode test:

- Requested mode: `appleAuto`.
- Persisted mode: `appleAuto`.
- `hardware verified=true` and `recovery required=false`.
- Every fan mode is `auto` or `system`; daemon and direct SMC readings agree.
- Ftst is confirmed absent/unavailable or readable as `0`/inactive; no unknown ownership.
- No unresolved SMC or daemon errors; RPMs and fan behavior are plausible.

If any check is unavailable or fails, stop before Phase 3.

## PHASE 3 — Cool Surface policy verification

Cool Surface is a temperature-dependent policy request, not a command that always enters manual mode. `CoolingPolicy.targetLevel()` returns no manual target below 50°C when fans are not already manual, unless thermal state is serious/critical. The daemon separately overrides to maximum for a 95°C hotspot. At/above 50°C the curve can request manual control. Existing manual control also follows its release hysteresis. The control temperature is the daemon's smoothed representative CPU/GPU temperature, not necessarily an individual sensor peak.

With the operator present and after explicit approval for this potentially SMC-writing request, run:

```bash
sudo coolermbpctl cool
sudo coolermbpctl status
sudo coolermbpsmc status
```

Record requested/persisted mode, control temperature, thermal state, hotspot, `target cooling`, fan modes/targets/RPMs, Ftst, strategy, and errors. Capture immediately; if the fans are manual, capture again around 25 seconds to observe response.

- Require requested and persisted mode `coolSurface`, `hardware verified=true`, and `recovery required=false`.
- If policy conditions do not require manual operation, fans remaining `auto`/`system` with no target cooling is a valid result, **not a failed transition**. Do not artificially heat the Mac to trigger the curve.
- If policy does require cooling, verify all fans are manual, targets are within reported min/max, and actual RPMs respond. Record whether strategy was `direct` or `ftstFallback` and the Ftst value/ownership.
- If preconditions, response, or Ftst ownership become uncertain, stop.

After capturing the result, request separate explicit approval to restore Apple Automatic, even if the policy left fans automatic. Then run `sudo coolermbpctl auto` and verify the criteria in Phase 5. Do not proceed to Phase 4 until that baseline is verified.

## PHASE 4 — Approved maximum-mode/manual-control verification

This is the deterministic manual-control check. Preconditions: the Phase 2 baseline or latest Phase 5 restoration verified Apple Automatic, with no recovery required, no unknown Ftst state, no competing fan controller, operator present, normal ambient conditions, and no stress workload. Do not run CatBoost or CPU/GPU stress tools.

After separate explicit approval for maximum fan control, run:

```bash
sudo coolermbpctl max
sudo coolermbpctl status
sudo coolermbpsmc status
```

Capture status immediately, then observe without adding load for approximately 25 seconds and collect status again. Require requested/persisted mode `maximum`, `hardware verified=true`, `recovery required=false`, all fans `manual`, targets at reported maximum and within limits, and actual RPM response. Record `strategy` and Ftst availability/value/ownership. On M2 Pro, do not expect or permit Ftst fallback if Ftst is unavailable; if direct mode fails, stop. On M3 Max, accept fallback only when observed and owned by CoolerMBP with verified Ftst readback; never override unknown ownership.

If any criterion is abnormal, stop and report. If the state is normal, obtain a **separate explicit approval** for restoration, then use Phase 5. Never automate this write-and-restore sequence.

## PHASE 5 — Verified Apple Automatic restoration

Restoration is a separate **SMC WRITE — explicit operator approval required** after each Phase 3 or Phase 4 request:

```bash
sudo coolermbpctl auto
sudo coolermbpctl status
sudo coolermbpsmc status
```

Capture immediately and again after approximately 25 seconds. Require requested/persisted `appleAuto`, `hardware verified=true`, `recovery required=false`, every fan `auto` or `system`, and direct/daemon state agreement. Ftst must be confirmed absent or read back as `0`; if CoolerMBP owned Ftst, ownership must be cleared. Review logs for verified restoration and no unresolved errors. A success message alone is insufficient.

If restoration fails or Ftst remains active/unknown, stop. Do not automatically run unknown-ownership recovery. Preserve diagnostics and request human review.

## PHASE 6 — Graceful daemon restart

Only restart from a Phase 5 verified Apple Automatic state. Obtain explicit approval for daemon shutdown/restart because shutdown may restore SMC state. Do not use `kill -9`, `SIGKILL`, or `launchctl kickstart -k`.

```bash
sudo coolermbpctl status
sudo launchctl bootout system/com.superstring.CoolerMBP.daemon
sudo launchctl bootstrap system /Library/LaunchDaemons/com.superstring.CoolerMBP.daemon.plist
sudo coolermbpctl ping
sudo coolermbpctl status
sudo coolermbpsmc status
```

After restart, repeat the Phase 2 baseline criteria. If bootout/bootstrap or verification fails, collect diagnostics and stop; do not force-kill or auto-recover.

## Target-specific notes

Apply Phases 0–6 identically to each target; do not transfer one Mac's Ftst result to the other.

- **M2 Pro:** expected inventory is 8 P-cores + 4 E-cores and macOS 27.0.1. Ftst was previously reported unavailable, but verify and record actual availability/value. If unavailable, manual-control testing must succeed through direct mode; otherwise stop.
- **M3 Max:** expected inventory is 12 P-cores + 4 E-cores and macOS 26.6. Ftst availability is unknown until read from this machine. Record observed Ftst state and only accept the guarded fallback if ownership/readback evidence is complete.

Record exact `hw.model`, macOS build, and CPU topology even when they differ from the expected target description. Stop if the physical machine is not the intended target.

## Stop criteria and emergency recovery

Stop the sequence if recovery is required, hardware verification is false/unavailable, any fan mode cannot be verified, daemon/direct readings disagree, RPM response is abnormal, Ftst is unexpectedly active/unknown/unreadable, SMC communication fails, a transition times out, or an unexplained daemon error occurs. Preserve current state and logs; do not continue to the next phase.

Emergency recovery is not a diagnostic. The standard helper can write SMC state and requires separate explicit operator approval after competing fan tools are stopped:

```bash
sudo /usr/local/sbin/coolermbp-recover
```

It tries daemon-supervised Automatic, then a lock-checked standalone restore. It does not authorize unknown fan/Ftst ownership. If it fails, preserve state and metadata. Never append `recover-unknown-ftst` automatically; any unknown-ownership override requires a distinct human decision and approval.

## Report template

Complete one report per Mac and per phase/transition. Attach the original diagnostic bundle path and retain timestamps.

```text
Machine: [M2 Pro / M3 Max]
Date/time local + timezone:
Date/time UTC:
Operator / approval reference:
Ambient temperature / power source / surface:
Other fan-control tools stopped:

macOS version/build:
Hardware model / chip / P-core / E-core counts:
CoolerMBP app version/build:
Installed daemon/CLI/SMC SHA-256:
Source checkout commit / dirty state:
Collector directory:
Unavailable commands/fields:

Phase/transition:
Command and approval time:
Requested mode / persisted mode:
Control temperature / thermal state / hotspot:
Hardware verified / recovery required:
Fans (index, mode/key, actual RPM, target RPM, min/max RPM):
Ftst availability / value / ownership:
SMC strategy:
Relevant errors/log events:
Observed fan response/noise:
Stop criterion triggered:
Outcome / next action:
```

## Expected results

| Phase/state | Expected mode and hardware state |
|---|---|
| Phase 2 baseline | requested/persisted `appleAuto`; verified; no recovery; fans `auto`/`system`; Ftst absent or inactive |
| Phase 3 Cool Surface below policy trigger | requested/persisted `coolSurface`; verified; fans may correctly remain `auto`/`system`; no artificial heating |
| Phase 3 when policy requests cooling | requested/persisted `coolSurface`; verified; all fans manual with in-range targets and responding RPM; record direct/Ftst path |
| Phase 4 maximum | requested/persisted `maximum`; verified; all fans manual at max target with response; record Ftst path |
| Phase 5 restoration | requested/persisted `appleAuto`; verified; no recovery; fans `auto`/`system`; Ftst absent or `0`, owned state cleared |
| Phase 6 restart | same verified Apple Automatic baseline after daemon returns |

These are expected observations, not hardware claims. Report only results captured on the target Mac.
