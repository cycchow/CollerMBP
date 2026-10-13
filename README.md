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

## Modes

- **Apple Automatic** — no manual override; macOS controls the fans.
- **Cool Surface** — proactive temperature-driven curve above.
- **Maximum** — both/all fans at the maximum RPM reported by SMC.

CoolerMBP first tries direct per-fan mode control. It considers the experimental `Ftst` fallback only when a fan reports system-managed mode and a direct write is rejected by SMC firmware. `Ftst` is never written when unavailable, unreadable, already active with unknown ownership, or when recovery metadata cannot be stored. Ownership metadata is written before `Ftst=1`; successful Apple Automatic reconciliation verifies each fan and the `Ftst` readback before clearing ownership.

### SMC write inventory

| Key | Value/type | When written | Verification and restoration |
|---|---|---|---|
| `F%dMd` or `F%dmd` | `1` (`ui8`) | Direct manual-mode request; key spelling is discovered per fan. | Read back mode `1`; fallback is only considered for firmware rejection `0x82` from mode `3`. Automatic restore writes `0` and verifies mode `0` or system-managed `3`. |
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

The independent root SMC tool does not depend on the daemon/XPC path:

```bash
sudo /usr/local/sbin/coolermbpsmc auto
```

If status reports active Ftst with unknown ownership, `auto` deliberately refuses to clear it. After stopping other fan-control tools and deciding to return control to macOS, the explicit administrative recovery is:

```bash
sudo /usr/local/sbin/coolermbpsmc recover-unknown-ftst
```

It restores fan modes, writes `Ftst=0` only on this explicit command, verifies the readback, and leaves recovery metadata intact unless CoolerMBP had recorded ownership.

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
- provides a daemon-independent `sudo coolermbpsmc auto` recovery path.
- records when it enabled `Ftst`, restores only an owned override, and reports active unknown ownership as recovery required;
- reconciles fan modes and owned `Ftst` state at daemon startup before honoring any saved cooling mode; after a crash, restart begins in Apple Automatic;
- provides read-only sensor inspection through `coolermbpsmc status`.

Even with these safeguards, manual SMC fan control can interfere with Apple's thermal management. Test it while monitoring temperatures before relying on it unattended.

If status reports active `Ftst` with unknown ownership, do not force `Ftst=0` blindly. Stop competing fan tools and use the explicit `coolermbpsmc auto` command only after deciding that returning control to macOS is appropriate. If that command cannot verify the result, retain the recovery metadata and inspect `/var/log/CoolerMBP.log` before any manual SMC intervention. SIGKILL, crashes, sleep, and power loss can interrupt transitions; the next daemon start attempts reconciliation.

For diagnostic logs, collect `sudo coolermbpctl status`, `sudo coolermbpsmc status`, and `sudo tail -100 /var/log/CoolerMBP.log`. For an external CPU/thermal sample, run `sudo powermetrics --samplers cpu_power,thermal` in a separate terminal. Compare repeated workloads using application throughput and completion time as primary measures; frequency and utilization alone do not identify effective work or prove a thermal cause. Record model, macOS build, power mode, workload, ambient conditions, and whether CoolerMBP was enabled.

## Build/distribution note

`build.sh` ad-hoc signs binaries for local use. Before distributing a compiled build to other Macs, use your own Developer ID signing and notarization workflow.

## Technical basis

The SMC interface and reported Ftst behavior are based on experimental reverse-engineering research, including [macos-smc-fan research notes](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md). Treat those observations as hardware-specific, not an Apple specification. See `THIRD_PARTY_NOTICES.md`.
