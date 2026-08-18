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

## Install

```bash
xcode-select --install   # only if you do not already have command-line tools
cd CoolerMBP
./install.sh
```

The installer builds locally, installs the root daemon and recovery CLI, places `CoolerMBP.app` in `/Applications`, resets fan control to Apple Automatic, then opens it.

## Modes

- **Apple Automatic** — no manual override; macOS controls the fans.
- **Cool Surface** — proactive temperature-driven curve above.
- **Maximum** — both/all fans at the maximum RPM reported by SMC.

## CLI

```bash
sudo coolermbpctl status
sudo coolermbpctl cool
sudo coolermbpctl max
sudo coolermbpctl auto
```

## Emergency recovery

The independent root SMC tool does not depend on the daemon/XPC path:

```bash
sudo /usr/local/sbin/coolermbpsmc auto
```

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

The uninstaller explicitly returns fan control to macOS before unloading/removing the daemon.

## Safety / limitations

This app writes undocumented Apple SMC keys. Apple does not provide a supported public API for manual fan control on Apple Silicon. The implementation therefore depends on reverse-engineered interoperability behavior and can stop working after firmware/macOS changes.

The code deliberately:

- never requests an RPM below the fan's hardware-reported minimum;
- refuses manual control if fan min/max limits are invalid;
- forces maximum cooling at an 80°C representative temperature, a 95°C hotspot, or `serious`/`critical` thermal state;
- restores Apple control and latches Apple Automatic if temperature acquisition/control fails;
- verifies mode/target writes and checks that fan RPM responds;
- accepts daemon connections only from the installed, root-owned app and root-only CLI;
- provides a daemon-independent `sudo coolermbpsmc auto` recovery path.

Even with these safeguards, manual SMC fan control can interfere with Apple's thermal management. Test it while monitoring temperatures before relying on it unattended.

## Build/distribution note

`build.sh` ad-hoc signs binaries for local use. Before distributing a compiled build to other Macs, use your own Developer ID signing and notarization workflow.

## Technical basis

The SMC interface and M1-M4 `Ftst` unlock behavior are based on public MIT-licensed Apple-Silicon fan-control interoperability research. See `THIRD_PARTY_NOTICES.md`.
