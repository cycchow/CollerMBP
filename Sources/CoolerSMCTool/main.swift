import Foundation
import CoolerSMC

func printStatus(_ controller: FanController) throws {
    let status = try controller.status()
    print(controller.hardwareInfo)
    for fan in status.fans {
        print("fan \(fan.index): \(fan.actualRPM) rpm target=\(fan.targetRPM) range=\(fan.minRPM)-\(fan.maxRPM) mode=\(fan.mode)")
    }
    let hottest = status.temperatures.sorted { $0.value > $1.value }.prefix(12)
    for (key, temp) in hottest {
        print(String(format: "%@: %.1f C", key, temp))
    }
}

do {
    let controller = try FanController()
    let command = CommandLine.arguments.dropFirst().first ?? "status"
    switch command {
    case "status": try printStatus(controller)
    case "auto", "reset":
        try controller.resetAppleAutomatic()
        print("fan control returned to macOS")
    case "max":
        try controller.setMaximum()
        print("fans set to hardware maximum")
    default:
        print("usage: sudo coolermbpsmc [status|auto|max]")
        exit(2)
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
