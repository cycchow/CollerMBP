import Foundation
import Darwin
import CoolerShared
import CoolerSMC

func printStatus(_ controller: FanController) throws {
    let status = try controller.status()
    print("hardware: \(hardwareModel())")
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("requested mode: \(requestedMode())")
    print("thermal state: \(thermalStateName())")
    print(controller.hardwareInfo)
    for fan in status.fans {
        print("fan \(fan.index): \(fan.actualRPM) rpm target=\(fan.targetRPM) range=\(fan.minRPM)-\(fan.maxRPM) mode=\(fan.mode) modeKey=\(fan.modeKey ?? "unknown")")
    }
    let hottest = status.temperatures.sorted { $0.value > $1.value }.prefix(12)
    for (key, temp) in hottest {
        print(String(format: "%@: %.1f C", key, temp))
    }
}

func requestedMode() -> String {
    let path = "/Library/Application Support/CoolerMBP/config.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let config = try? JSONDecoder().decode(DaemonConfig.self, from: data) else { return "unknown" }
    return config.mode.rawValue
}

func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var value = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: value)
}

do {
    let controller = try FanController()
    let command = CommandLine.arguments.dropFirst().first ?? "status"
    switch command {
    case "status": try printStatus(controller)
    case "diagnose":
        try printStatus(controller)
        print("diagnostic is read-only; collect CPU power separately with: sudo powermetrics --samplers cpu_power,thermal")
    case "auto", "reset":
        let writerLock = try SMCWriterLock()
        defer { withExtendedLifetime(writerLock) {} }
        try controller.resetAppleAutomatic()
        print("fan control returned to macOS")
    case "recover-unknown-ftst":
        let writerLock = try SMCWriterLock()
        defer { withExtendedLifetime(writerLock) {} }
        try controller.resetAppleAutomatic(allowUnknownFtstRelease: true)
        print("unknown Ftst override explicitly released and verified")
    case "lock-check":
        let writerLock = try SMCWriterLock()
        defer { withExtendedLifetime(writerLock) {} }
        print("SMC writer lock acquired")
    case "max":
        fputs("Standalone maximum control is disabled. Use sudo coolermbpctl max while the daemon is running.\n", stderr)
        exit(2)
    default:
        print("usage: sudo coolermbpsmc [status|diagnose|auto|recover-unknown-ftst|lock-check]")
        exit(2)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
