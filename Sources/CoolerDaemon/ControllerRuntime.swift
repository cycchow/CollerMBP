import Foundation
import CoolerShared
import CoolerSMC

final class ControllerRuntime {
    private let queue = DispatchQueue(label: "com.superstring.CoolerMBP.controller")
    private let fanController: FanController
    private let policy = CoolingPolicy()
    private var timer: DispatchSourceTimer?
    private var config: DaemonConfig
    private var latestStatus: DaemonStatus
    private var lastAppliedLevel: Double?
    private var lastApplyDate: Date = .distantPast
    private var belowReleaseSince: Date?
    private var manualSince: Date?
    private var temperatureSmoother = TemperatureMovingAverage(sampleCount: 10)
    private var lastError: String?
    private var missingSensorPolls = 0
    private var lastValidControlTemperature: Double?
    private var fanResponseFailurePolls = 0

    // A transient SMC sensor gap should not immediately drop manual fan control.
    private static let missingSensorPollLimit = 3
    private static let fanResponseVerificationDelay: TimeInterval = 20
    private static let fanResponseFailurePollLimit = 3

    private let configURL = URL(fileURLWithPath: "/Library/Application Support/CoolerMBP/config.json")

    init() throws {
        fanController = try FanController()
        config = Self.loadConfig(from: configURL) ?? DaemonConfig()
        latestStatus = DaemonStatus(
            timestamp: Date(), mode: config.mode,
            controlTemperature: nil, cpuPeakTemperature: nil, gpuPeakTemperature: nil,
            hottestSensorTemperature: nil, thermalState: Self.thermalStateName(),
            targetCoolingLevel: nil, fans: [], temperatures: [:],
            hardwareInfo: fanController.hardwareInfo, lastError: nil
        )
    }

    func start() {
        queue.async {
            self.tick()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func shutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            do { try fanController.resetAppleAutomatic() }
            catch { fputs("CoolerMBP: failed to restore Apple fan control: \(error)\n", stderr) }
        }
    }

    func setMode(_ mode: CoolingMode, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                var candidate = self.config
                candidate.mode = mode
                try self.saveConfig(candidate)
                self.config = candidate
                self.lastAppliedLevel = nil
                self.lastApplyDate = .distantPast
                self.belowReleaseSince = nil
                self.manualSince = nil
                self.missingSensorPolls = 0
                self.lastValidControlTemperature = nil
                self.fanResponseFailurePolls = 0
                self.lastError = nil
                self.tick()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func getStatus(completion: @escaping (DaemonStatus) -> Void) {
        queue.async { completion(self.latestStatus) }
    }

    private func tick() {
        do {
            let raw = try fanController.status()
            if lastAppliedLevel != nil,
               let manualSince,
               Date().timeIntervalSince(manualSince) >= Self.fanResponseVerificationDelay {
                do {
                    try FanController.verifyFanResponse(raw.fans)
                    fanResponseFailurePolls = 0
                } catch {
                    fanResponseFailurePolls += 1
                    if fanResponseFailurePolls >= Self.fanResponseFailurePollLimit {
                        throw error
                    }
                }
            }
            let thermalState = Self.thermalStateName()
            let cpuPeak = Self.peak(raw.temperatures, prefixes: ["TC", "Tp"])
            let gpuPeak = Self.peak(raw.temperatures, prefixes: ["TG", "Tg"])
            let hottest = raw.temperatures.values.max()
            let representative = TemperatureControl.representative(from: raw.temperatures)
            let controlTemperature = representative.map { temperatureSmoother.add($0) }

            var targetLevel: Double?
            var tickError: String?

            switch config.mode {
            case .appleAuto:
                missingSensorPolls = 0
                lastValidControlTemperature = nil
                fanResponseFailurePolls = 0
                if lastAppliedLevel != nil || raw.fans.contains(where: { $0.mode == "manual" }) {
                    try fanController.resetAppleAutomatic()
                }
                lastAppliedLevel = nil
                belowReleaseSince = nil
                manualSince = nil

            case .maximum:
                try apply(level: 1.0)
                targetLevel = 1.0

            case .coolSurface:
                guard let temperature = controlTemperature else {
                    missingSensorPolls += 1
                    if lastAppliedLevel != nil && missingSensorPolls < Self.missingSensorPollLimit {
                        latestStatus = makeStatus(
                            raw: raw,
                            thermalState: thermalState,
                            cpuPeak: cpuPeak,
                            gpuPeak: gpuPeak,
                            hottest: hottest,
                            control: lastValidControlTemperature,
                            target: lastAppliedLevel,
                            error: "Temporary thermal sensor gap; retaining the last fan target."
                        )
                        return
                    }
                    let message = "No valid thermal sensors were found; returned fan control to macOS."
                    recordSafetyFallback(message)
                    try fanController.resetAppleAutomatic()
                    try latchAppleAutomatic()
                    lastAppliedLevel = nil
                    belowReleaseSince = nil
                    manualSince = nil
                    fanResponseFailurePolls = 0
                    temperatureSmoother.reset()
                    tickError = message
                    latestStatus = makeStatus(raw: raw, thermalState: thermalState, cpuPeak: cpuPeak, gpuPeak: gpuPeak, hottest: hottest, control: nil, target: nil, error: tickError)
                    return
                }

                missingSensorPolls = 0
                lastValidControlTemperature = temperature

                if temperature < CoolingPolicy.releaseTemperature {
                    if belowReleaseSince == nil { belowReleaseSince = Date() }
                } else {
                    belowReleaseSince = nil
                }
                let secondsBelowRelease = belowReleaseSince.map { Date().timeIntervalSince($0) } ?? 0
                let currentlyManual = lastAppliedLevel != nil || raw.fans.contains(where: { $0.mode == "manual" })
                let desired: Double?
                if let hottest, hottest >= CoolingPolicy.hotspotEmergencyTemperature {
                    desired = 1.0
                } else {
                    desired = policy.targetLevel(
                        temperature: temperature,
                        thermalState: thermalState,
                        currentlyManual: currentlyManual,
                        secondsBelowRelease: secondsBelowRelease
                    )
                }

                if let desired {
                    // Heat gets an immediate response. Cooling backs off gradually.
                    let level: Double
                    if let previous = lastAppliedLevel, desired < previous {
                        level = max(desired, previous - 0.10)
                    } else {
                        level = desired
                    }
                    try apply(level: level)
                    targetLevel = level
                } else {
                    if currentlyManual {
                        try fanController.resetAppleAutomatic()
                    }
                    lastAppliedLevel = nil
                    manualSince = nil
                    targetLevel = nil
                }
            }

            if let tickError {
                lastError = tickError
            } else if config.mode != .appleAuto {
                lastError = nil
            }
            latestStatus = makeStatus(raw: raw, thermalState: thermalState, cpuPeak: cpuPeak, gpuPeak: gpuPeak, hottest: hottest, control: controlTemperature, target: targetLevel, error: tickError)
        } catch {
            let operationError = String(describing: error)
            lastError = operationError
            // Failure to read/control sensors is safer when macOS regains authority.
            do { try fanController.resetAppleAutomatic() }
            catch { lastError = "\(operationError); recovery failed: \(error)" }
            do { try latchAppleAutomatic() }
            catch { lastError = "\(lastError ?? operationError); unable to persist safety mode: \(error)" }
            lastAppliedLevel = nil
            manualSince = nil
            missingSensorPolls = 0
            lastValidControlTemperature = nil
            fanResponseFailurePolls = 0
            temperatureSmoother.reset()
            recordSafetyFallback(lastError ?? operationError)
            latestStatus = DaemonStatus(
                timestamp: Date(), mode: config.mode,
                controlTemperature: nil, cpuPeakTemperature: nil, gpuPeakTemperature: nil,
                hottestSensorTemperature: nil, thermalState: Self.thermalStateName(),
                targetCoolingLevel: nil, fans: [], temperatures: [:],
                hardwareInfo: fanController.hardwareInfo, lastError: lastError
            )
        }
    }

    private func apply(level: Double) throws {
        let clamped = min(max(level, 0), 1)
        let needsRefresh = Date().timeIntervalSince(lastApplyDate) >= 10
        if lastAppliedLevel == nil || abs((lastAppliedLevel ?? 0) - clamped) >= 0.025 || needsRefresh {
            try fanController.setCoolingLevel(clamped)
            if lastAppliedLevel == nil {
                manualSince = Date()
                fanResponseFailurePolls = 0
            }
            lastAppliedLevel = clamped
            lastApplyDate = Date()
        }
    }

    private func makeStatus(
        raw: RawThermalStatus,
        thermalState: String,
        cpuPeak: Double?, gpuPeak: Double?, hottest: Double?, control: Double?,
        target: Double?, error: String?
    ) -> DaemonStatus {
        DaemonStatus(
            timestamp: Date(), mode: config.mode,
            controlTemperature: control,
            cpuPeakTemperature: cpuPeak,
            gpuPeakTemperature: gpuPeak,
            hottestSensorTemperature: hottest,
            thermalState: thermalState,
            targetCoolingLevel: target,
            fans: raw.fans,
            temperatures: raw.temperatures,
            hardwareInfo: fanController.hardwareInfo,
            lastError: error ?? lastError
        )
    }

    private func saveConfig(_ config: DaemonConfig) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    private func latchAppleAutomatic() throws {
        var candidate = config
        candidate.mode = .appleAuto
        try saveConfig(candidate)
        config = candidate
    }

    private func recordSafetyFallback(_ message: String) {
        lastError = message
        fputs("CoolerMBP: \(message)\n", stderr)
    }

    private static func loadConfig(from url: URL) -> DaemonConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DaemonConfig.self, from: data)
    }

    private static func peak(_ temperatures: [String: Double], prefixes: [String]) -> Double? {
        temperatures.compactMap { key, value in
            prefixes.contains(where: { key.hasPrefix($0) }) ? value : nil
        }.max()
    }

    private static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
