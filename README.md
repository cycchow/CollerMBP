# CoolerMBP

A small native macOS menu-bar fan controller aimed at keeping an Apple-silicon MacBook Pro chassis cooler in a warm room.

## Target

- Apple Silicon Mac with fans (primary target: M3 Max MacBook Pro)
- macOS 13 or later
- Xcode / Command Line Tools with Swift
- Local/admin installation

This package is source-only. It has **not been hardware-tested by the package authoring environment on an M3 Max** and intentionally does not include a pre-signed binary.

## What it does

- Shows the current control temperature in the menu bar (`58°C`).
- Shows CPU/GPU peaks, hottest discovered SMC sensor, fan RPM and current mode.
- Runs the cooling policy in a root launchd daemon, so closing the menu UI does not stop automatic cooling.
- Optional **Cool Surface** curve is tuned for a warm 24-33°C room:

| Temperature | Cooling level* |
|---|---:|
| 58°C | 25% |
| 65°C | 40% |
| 70°C | 60% |
| 75°C | 80% |
| 80°C | 100% |

`*` Temperature is the 20-second moving average of the warmer CPU/GPU sensor-group average. Cooling level is interpolated between each fan's reported minimum and maximum RPM, not a percentage of raw max RPM.

- macOS thermal state `fair` forces at least 72% cooling.
- macOS thermal state `serious` or `critical` forces 100% cooling.
- Any discovered 95°C hotspot forces 100% cooling immediately.
- Below 48°C for 30 seconds, fan control is returned to macOS.
- Sensor/control failures return fan authority to macOS where possible.
- The launchd daemon uses `KeepAlive` so it is restarted if it exits.
- Only one CoolerMBP process may write SMC keys at a time. The daemon holds an OS file lock; the standalone recovery tool uses the same lock.

## Install

```bash
xcode-select --install   # only if you do not already have command-line tools
cd CoolerMBP
./install.sh
```

The installer builds locally, asks an existing daemon to restore Apple Automatic and stops it before replacing files, installs the root daemon and recovery CLI, then opens the app. An upgrade aborts if the running version cannot confirm Automatic mode.

For approval-gated, read-only-first validation on the M2 Pro and M3 Max, see [the hardware validation runbook](docs/HARDWARE_VALIDATION.md). The diagnostic collector is `scripts/collect-hardware-diagnostics.sh`.

## Modes

- **Apple Automatic** — no manual override; macOS controls the fans.
- **Cool Surface** — proactive temperature-driven curve above.
- **Maximum** — both/all fans at the maximum RPM reported by SMC.

CoolerMBP first tries direct per-fan mode control. It considers the experimental `Ftst` fallback only when a fan reports system-managed mode and a direct write is rejected by SMC firmware. `Ftst` is never written when unavailable, unreadable, already active with unknown ownership, or when recovery metadata cannot be stored. Ftst ownership metadata is separate from fan-control ownership metadata.

Before a manual transition, the daemon atomically records each fan's prior state and intended target in `/Library/Application Support/CoolerMBP/fan-recovery.json`; it marks the record active only after target readback succeeds. On restart or an ordinary Auto request, the daemon restores fans only when the recorded transition matches the observed mode keys and targets. Missing, invalid, or mismatched records leave manual fans untouched and set recovery required. This record is evidence of CoolerMBP's transition, not an Apple-provided process identity: another controller that writes identical values cannot be distinguished by AppleSMC.

### SMC write inventory

| Key | Value/type | When written | Verification and restoration |
|---|---|---|---|
| `F%dmd` (preferred) or `F%dMd` (fallback only when lowercase is confirmed absent) | `1` (`ui8`) | Direct manual-mode request; the selected key is cached per fan for the connection. | Read back mode `1`; fallback is only considered for firmware rejection `0x82` from mode `3`. Automatic restore writes `0` and verifies mode `0` or system-managed `3`. |
| `F%dTg` | Calculated target RPM (`flt`) | Manual operation, using that fan's reported min/max range and the requested cooling level. | Read back mode and target within 100 RPM; failure triggers verified automatic restoration. |
| `Ftst` | `1` / `0` (`ui8`) | `1` only for the compatible fallback after root-owned recovery metadata is atomically saved; `0` only to release an owned flag, or from the explicit unknown-ownership recovery command. | Read back the exact value. Ownership lives at `/Library/Application Support/CoolerMBP/recovery.json` and is cleared only after verified release. |

`F%dAc`, `F%dMn`, and `F%dMx` are read only. CoolerMBP does not write `Ftst` on direct-mode success and never writes mode `3`.

SMC mode values reported by community reverse engineering are `0` (automatic), `1` (manual target), and `3` (system-managed/mitigation state). These meanings are not an Apple specification. The research notes report different behavior across tested M1, M4, and M5 systems. A separate [MacFanControl project](https://github.com/raminsharifi/MacFanControl) reports M3 Pro tests, while the research notes leave M3 applicability open; neither establishes behavior on this M3 Max or the M2 Pro. No hardware support claim is made for either machine until manually verified.

## CLI

```bash
sudo coolermbpctl status
sudo coolermbpctl ping  # Test XPC connectivity without waiting for sensor polling.
sudo coolermbpctl cool
sudo coolermbpctl max
sudo coolermbpctl auto
```

## Emergency recovery

Try the daemon-supervised restore first. If it times out or cannot respond, the recovery helper disables and requests daemon shutdown, waits up to 20 seconds for the service to unload and the writer lock to become available, then runs and verifies the standalone restore:

```bash
sudo /usr/local/sbin/coolermbp-recover
```

The standalone tool is read-only except for explicit recovery commands; use `coolermbpctl max` for maximum cooling while the daemon is available.

Ordinary `auto` refuses manual fan states without a matching CoolerMBP transition record. If the daemon is running, the CLI and app report the explicit recovery command. After stopping the daemon and competing fan-control tools, confirming the writer lock is released, and deciding to override unknown fan ownership, run:

```bash
sudo /usr/local/sbin/coolermbpsmc recover-unknown-fans
```

Unknown Ftst ownership remains a separate condition. After stopping other fan-control tools and deciding to return control to macOS, run:

```bash
sudo /usr/local/sbin/coolermbpsmc recover-unknown-ftst
```

The `recover-unknown-ftst` command authorizes releasing unknown Ftst only when fan ownership is already known. If both fan and Ftst ownership are unknown, the combined administrative override is `sudo /usr/local/sbin/coolermbpsmc recover-unknown`. Each command verifies Apple Automatic before reporting success. These commands can overwrite another fan controller's settings; use them only after deciding to return control to macOS. After explicit recovery, rerun `sudo /usr/local/sbin/coolermbp-recover` to verify the state and restart the daemon.

To inspect raw status:

```bash
sudo /usr/local/sbin/coolermbpsmc status
```

If the daemon itself needs inspection:

```bash
sudo launchctl print system/com.superstring.CoolerMBP.daemon
tail -100 /var/log/CoolerMBP.log
```

## Remove

```bash
./uninstall.sh
```

The uninstaller asks the daemon to restore Apple Automatic, unloads it, verifies via the independent recovery tool, and only then removes recovery metadata. If verification fails, removal stops and the metadata remains.

## Safety / limitations

This app writes undocumented Apple SMC keys. Apple does not provide a supported public API for manual fan control on Apple Silicon. The implementation therefore depends on reverse-engineered interoperability behavior and can stop working after firmware/macOS changes.

Manual control can alter interactions with macOS thermal management. `Ftst` findings are experimental and hardware-specific. CoolerMBP does not write CPU frequency, voltage, power-limit, clock, or AppleCLPC settings, and it does not directly control P-core frequency. The reported performance changes do not establish that CoolerMBP or `Ftst` caused CPU performance degradation.

The code deliberately:

- never requests an RPM below the fan's hardware-reported minimum;
- refuses manual control if fan min/max limits are invalid;
- forces maximum cooling at an 80°C representative temperature, a 95°C hotspot, or `serious`/`critical` thermal state;
- restores Apple control and latches Apple Automatic if temperature acquisition/control fails;
- verifies mode/target writes and checks that fan RPM responds;
- accepts daemon connections only from the installed, root-owned app and root-only CLI;
- provides daemon-first recovery with a bounded, lock-checked standalone fallback through `sudo coolermbp-recover`.
- records when it enabled `Ftst`, restores only an owned override, and reports active unknown ownership as recovery required;
- reconciles fan modes and owned `Ftst` state at daemon startup before honoring any saved cooling mode; after a crash, restart begins in Apple Automatic;
- provides read-only sensor inspection through `coolermbpsmc status`.

Even with these safeguards, manual SMC fan control can interfere with Apple's thermal management. Test it while monitoring temperatures before relying on it unattended.

If status reports active `Ftst` with unknown ownership, do not force `Ftst=0` blindly. The ordinary recovery command blocks before any SMC write. Stop competing fan tools, decide that returning control to macOS is appropriate, then use `sudo /usr/local/sbin/coolermbpsmc recover-unknown-ftst`. If recovery cannot verify the result, the helper leaves the daemon disabled and retains recovery metadata. SIGKILL, crashes, sleep, and power loss can interrupt transitions; the next daemon start attempts reconciliation.

For diagnostic logs, collect `sudo coolermbpctl status`, `sudo coolermbpsmc status`, and `sudo tail -100 /var/log/CoolerMBP.log`. For an external CPU/thermal sample, run `sudo powermetrics --samplers cpu_power,thermal` in a separate terminal. Compare repeated workloads using application throughput and completion time as primary measures; frequency and utilization alone do not identify effective work or prove a thermal cause. Record model, macOS build, power mode, workload, ambient conditions, and whether CoolerMBP was enabled.

## Build/distribution note

`build.sh` ad-hoc signs binaries for local use. Before distributing a compiled build to other Macs, use your own Developer ID signing and notarization workflow.

## Technical basis

The SMC interface and reported Ftst behavior are based on experimental reverse-engineering research, including [macos-smc-fan research notes](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md). Treat those observations as hardware-specific, not an Apple specification. See `THIRD_PARTY_NOTICES.md`.
