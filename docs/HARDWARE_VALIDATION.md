# CoolerMBP hardware validation

This runbook permits **read-only inventory and separately approved Apple Automatic verification only** on the M2 Pro and M3 Max. Manual fan-control validation is disabled: no production model has validated evidence for a safe SMC mode/target write sequence. Hardware validation remains **unverified** until the allowed read-only/Automatic procedures have actually been run and captured in a report. No commands in this document are automated.

A real Mac14,9 M2 Pro failure is recorded below. **Do not repeat M2 Pro Phase 4. M3 Max manual control is not yet validated.** Read-only inventory and Apple Automatic verification do not validate manual fan control.

## Safety rules

- Read-only commands do not request a mode change. Any command that can change fan mode, fan target, or Ftst is marked **SMC WRITE — explicit operator approval required**. Get approval for each transition before running that command.
- Do not request or test manual fan mode on either target. Do not run CatBoost, CPU/GPU stress workloads, artificial heating, or cooling-curve changes. No stress testing is authorized. Do not crash or SIGKILL the daemon.
- Do not invoke unknown-ownership recovery automatically. It is outside the normal validation sequence.
- If a stop criterion occurs, stop transitions. Collect read-only diagnostics, preserve the output, and report the observed state. Do not restart, install, or attempt recovery automatically.
- Installation/upgrade, service unload, and daemon restart are out of scope. Do not run them as part of this validation plan.

## Command classification

| Command | Classification | Notes |
|---|---|---|
| `sw_vers`, `sysctl`, `test -e`, `launchctl print`, `tail` | READ ONLY | System/hardware inventory and logs. |
| `sudo coolermbpctl status` | READ ONLY | Daemon state, requested/persisted mode, temperatures, fan readings and verification flags. |
| `sudo coolermbpsmc status` | READ ONLY | Direct fan and Ftst readings, ownership and latest transition strategy. |
| `sudo coolermbpctl ping` | READ ONLY | XPC reachability only. |
| `sudo scripts/collect-hardware-diagnostics.sh` | READ ONLY with respect to SMC | Writes a local diagnostic bundle only; it does not issue a mode/recovery command. |
| `sudo coolermbpctl cool` | May request SMC writes; do not use for hardware validation | A low-temperature request may be accepted while fans remain automatic. If policy requests manual cooling, the production eligibility gate rejects it. Neither result validates manual cooling. |
| `sudo coolermbpctl max` | MANUAL CONTROL DISABLED | Do not run on the M2 Pro or M3 Max. No production hardware model is currently eligible. |
| `sudo coolermbpctl auto` | SMC WRITE — separate explicit operator approval required | Requests Apple Automatic and verifies hardware readback. |
| `./install.sh` | OUT OF SCOPE — do not run | Installation may unload the daemon and write SMC state. |
| `sudo launchctl bootout ...` | OUT OF SCOPE — do not run | Service unload/restart is not authorized by this runbook. |
| `sudo /usr/local/sbin/coolermbp-recover` | SMC WRITE — explicit operator approval required | Daemon-first Apple Automatic recovery; never treats unknown Ftst ownership as approved. |
| `coolermbpsmc recover-unknown-ftst` | Explicit unknown-Ftst SMC WRITE | Not part of the automated or normal validation procedure. Requires separate review and approval. |

`coolermbpsmc status` reports Ftst availability/value/ownership and the last SMC strategy. Read-only inventory and verified Apple Automatic state are not manual-control validation. Ftst availability by itself does not mean Ftst was written.

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

## PHASE 1 — Installation or upgrade is out of scope

Do not run `./install.sh`, unload the daemon, or restart/enable/bootstrap services under this validation plan. Installation and service lifecycle changes are not needed for read-only inventory or Apple Automatic verification. If an installation/recovery failure already exists, preserve its metadata and logs and inspect only through read-only status commands; do not bootstrap or retry state-changing commands here.

## PHASE 2 — Post-installation baseline verification

If CoolerMBP is already installed, collect a bundle and inspect both status sources:

```bash
sudo scripts/collect-hardware-diagnostics.sh
sudo coolermbpctl ping
sudo coolermbpctl status
sudo coolermbpsmc status
```

Use these as the baseline criteria for verified Apple Automatic:

- Requested mode: `appleAuto`.
- Persisted mode: `appleAuto`.
- `hardware verified=true` and `recovery required=false`.
- Every fan mode is `auto` or `system`; daemon and direct SMC readings agree.
- Ftst is confirmed absent/unavailable or readable as `0`/inactive; no unknown ownership.
- No unresolved SMC or daemon errors; RPMs and fan behavior are plausible.

If any check is unavailable or fails, stop; no manual-control phase is permitted.

## PHASE 3 — Cool Surface request observation (not manual-control validation)

Cool Surface is temperature-dependent. A low-temperature request may be accepted while fans remain `auto`/`system`; that is only a policy/configuration observation, not validated manual cooling. The policy can request manual control at higher temperatures or under serious/critical thermal conditions. **Do not issue a Cool Surface request as part of this hardware-validation runbook, and do not heat the machine to trigger it.** If Cool Surface was requested outside this procedure, use read-only status and stop if any fan reports Manual or recovery is required.

## PHASE 4 — Manual-control validation is disabled

Do not run `sudo coolermbpctl max` and do not attempt any other manual-mode request on either target. No production hardware model has validated evidence for the required SMC mode/target sequence.

### Recorded M2 Pro incident

On the real Mac14,9 Apple M2 Pro running macOS 27.0.1, `sudo coolermbpctl max` received an accepted `F0Md` mode=1 write. Immediate readback initially did not confirm Manual. Fan 0 later reported Manual with a 0 RPM target; Fan 1 remained Apple Automatic. Normal Apple Automatic recovery refused because fan ownership could not be verified. The operator unloaded the daemon, verified writer-lock availability, and explicitly used `recover-unknown-fans`. Recovery succeeded; both fans returned to Apple Automatic.

**Manual control is disabled on Mac14,9. M2 Pro Phase 4 must not be repeated. M3 Max manual control is not yet validated.** Do not use a Cool Surface request at low temperature as a substitute: it may be accepted while fans remain automatic and does not demonstrate manual cooling.

No stress testing is authorized. Any future experimental manual-control opt-in requires a separate design review and explicit operator authorization; this runbook does not provide an override.

## PHASE 5 — Verified Apple Automatic restoration

Apple Automatic restoration is separate from manual eligibility and remains available for ordinary recovery. Any explicit request that writes fan modes is an **SMC WRITE — explicit operator approval required**:

```bash
sudo coolermbpctl auto
sudo coolermbpctl status
sudo coolermbpsmc status
```

Capture immediately and again after approximately 25 seconds. Require requested/persisted `appleAuto`, `hardware verified=true`, `recovery required=false`, every fan `auto` or `system`, and direct/daemon state agreement. Ftst must be confirmed absent or read back as `0`; if CoolerMBP owned Ftst, ownership must be cleared. Review logs for verified restoration and no unresolved errors. A success message alone is insufficient.

If restoration fails or Ftst remains active/unknown, stop. Do not automatically run unknown-ownership recovery. Preserve diagnostics and request human review.

## PHASE 6 — Service restart is out of scope

Do not unload, enable, bootstrap, or restart the daemon as part of this validation plan. Preserve the current service state and use read-only status/log collection only.

## Target-specific notes

Use Phase 0 for read-only inventory and Phase 2/5 for Apple Automatic verification. These do not validate manual control. Do not transfer one Mac's Ftst result to the other.

- **M2 Pro:** expected inventory is 8 P-cores + 4 E-cores and macOS 27.0.1. Ftst was previously reported unavailable; verify and record actual availability/value. Manual control is disabled on Mac14,9, and Phase 4 must not be repeated.
- **M3 Max:** expected inventory is 12 P-cores + 4 E-cores and macOS 26.6. Ftst availability is unknown until read from this machine. Manual control is not yet validated and is disabled.

Record exact `hw.model`, macOS build, and CPU topology even when they differ from the expected target description. Stop if the physical machine is not the intended target.

## Stop criteria and emergency recovery

Stop the sequence if recovery is required, hardware verification is false/unavailable, any fan mode cannot be verified, daemon/direct readings disagree, RPM response is abnormal, Ftst is unexpectedly active/unknown/unreadable, SMC communication fails, a transition times out, or an unexplained daemon error occurs. Preserve current state and logs; do not continue to the next phase.

Emergency recovery is not a diagnostic. The standard helper can write SMC state and requires separate explicit operator approval after competing fan tools are stopped:

```bash
sudo /usr/local/sbin/coolermbp-recover
```

It verifies daemon-supervised Automatic first. If that request fails, it requests normal service shutdown, waits for unload and the writer lock, then tries one lock-protected standalone restore. It verifies fan/Ftst readback before enabling/bootstrap once and reports success only after the daemon returns and status verifies Apple Automatic. It does not disable the service permanently or authorize unknown fan/Ftst ownership. If it fails, preserve the printed `/var/tmp/CoolerMBP-recovery-*` snapshot, report, and logs. Never append `recover-unknown-ftst` automatically; any unknown-ownership override requires a distinct human decision and approval.

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
| Cool Surface request outside this runbook | May be accepted below policy trigger with fans `auto`/`system`; policy acceptance is not manual-cooling validation |
| Phase 3 when policy would request manual cooling | request is rejected by the production eligibility gate; collect state and stop; this is not validation |
| Phase 4 manual control | disabled; do not run `coolermbpctl max` on either target |
| Phase 5 restoration | requested/persisted `appleAuto`; verified; no recovery; fans `auto`/`system`; Ftst absent or `0`, owned state cleared |
| Phase 6 service lifecycle | out of scope; do not unload or restart services |

These are expected observations, not hardware claims. Report only results captured on the target Mac.
