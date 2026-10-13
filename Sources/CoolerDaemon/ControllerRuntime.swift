import Foundation
import CoolerShared
import CoolerSMC

final class ControllerRuntime {
    private let queue = DispatchQueue(label: "com.superstring.CoolerMBP.controller")
    private let writerLock: SMCWriterLock?
    private let fanController: FanController
    private let policy = CoolingPolicy()
    private var timer: DispatchSourceTimer?
    private var config: DaemonConfig
    private let statusLock = NSLock()
    private var cachedStatus: DaemonStatus
    private var latestStatus: DaemonStatus {
        get {
            statusLock.lock()
            defer { statusLock.unlock() }
            return cachedStatus
        }
        set {
            statusLock.lock()
            defer { statusLock.unlock() }
            cachedStatus = newValue
        }
    }
    private var lastAppliedLevel: Double?
    private var lastApplyDate: Date = .distantPast
    private var belowReleaseSince: Date?
    private var manualSince: Date?
    private var temperatureSmoother = TemperatureMovingAverage(sampleCount: 10)
    private var lastError: String?
    private var missingSensorPolls = 0
    private var lastValidControlTemperature: Double?
    private var fanResponseFailurePolls = 0
    private var recoveryRequired = false

    // A transient SMC sensor gap should not immediately drop manual fan control.
    private static let missingSensorPollLimit = 3
    private static let fanResponseVerificationDelay: TimeInterval = 20
    private static let fanResponseFailurePollLimit = 3

    private let configURL = URL(fileURLWithPath: "/Library/Application Support/CoolerMBP/config.json")

    init() throws {
        writerLock = try? SMCWriterLock()
        fanController = try FanController(writeEnabled: writerLock != nil)
        config = Self.loadConfig(from: configURL) ?? DaemonConfig()
        cachedStatus = DaemonStatus(
            timestamp: Date(), mode: config.mode,
            controlTemperature: nil, cpuPeakTemperature: nil, gpuPeakTemperature: nil,
            hottestSensorTemperature: nil, thermalState: Self.thermalStateName(),
            targetCoolingLevel: nil, fans: [], temperatures: [:],
            hardwareInfo: fanController.hardwareInfo, lastError: "Waiting for the first SMC sensor poll."
        )
    }

    func start() {
        queue.async { [self] in
            do {
                // Never resume a persisted manual request before reconciling
                // hardware state left by a previous daemon instance.
                try self.fanController.resetAppleAutomatic()
                try self.latchAppleAutomatic()
                self.lastError = nil
                self.tick()
            } catch {
                self.lastError = "Startup recovery required: \(error)"
                self.recoveryRequired = true
                self.recordSafetyFallback(self.lastError!)
            }
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
            if mode == .appleAuto {
                do {
                    try self.fanController.resetAppleAutomatic()
                    let raw = try self.fanController.status()
                    guard raw.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
                        throw RuntimeTransitionError.failed("fan mode readback did not confirm Apple Automatic")
                    }
                    var candidate = self.config
                    candidate.mode = .appleAuto
                    try self.saveConfig(candidate)
                    self.config = candidate
                    self.recoveryRequired = false
                    self.lastError = nil
                    self.lastAppliedLevel = nil
                    self.lastApplyDate = .distantPast
                    self.belowReleaseSince = nil
                    self.manualSince = nil
                    self.missingSensorPolls = 0
                    self.lastValidControlTemperature = nil
                    self.fanResponseFailurePolls = 0
                    self.temperatureSmoother.reset()
                    self.latestStatus = DaemonStatus(
                        timestamp: Date(), mode: .appleAuto,
                        controlTemperature: nil,
                        cpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TC", "Tp"]),
                        gpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TG", "Tg"]),
                        hottestSensorTemperature: raw.temperatures.values.max(),
                        thermalState: Self.thermalStateName(), targetCoolingLevel: nil,
                        fans: raw.fans, temperatures: raw.temperatures,
                        hardwareInfo: self.fanController.hardwareInfo, lastError: nil,
                        recoveryRequired: false
                    )
                    completion(.success(()))
                } catch {
                    self.recoveryRequired = true
                    self.lastError = "Apple Automatic recovery failed: \(error)"
                    let raw = try? self.fanController.status()
                    self.latestStatus = DaemonStatus(
                        timestamp: Date(), mode: self.config.mode,
                        controlTemperature: nil,
                        cpuPeakTemperature: raw.flatMap { Self.peak($0.temperatures, prefixes: ["TC", "Tp"]) },
                        gpuPeakTemperature: raw.flatMap { Self.peak($0.temperatures, prefixes: ["TG", "Tg"]) },
                        hottestSensorTemperature: raw?.temperatures.values.max(),
                        thermalState: Self.thermalStateName(), targetCoolingLevel: nil,
                        fans: raw?.fans ?? [], temperatures: raw?.temperatures ?? [:],
                        hardwareInfo: self.fanController.hardwareInfo, lastError: self.lastError,
                        recoveryRequired: true
                    )
                    completion(.failure(error))
                }
                return
            }

            let previous = self.config
            do {
                if self.recoveryRequired && mode != .appleAuto {
                    throw RuntimeTransitionError.failed("Recovery is required; manual modes are disabled")
                }
                var candidate = self.config
                candidate.mode = mode
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
                if let error = self.lastError {
                    throw RuntimeTransitionError.failed(error)
                }
                do {
                    try self.saveConfig(candidate)
                } catch {
                    let persistenceError = error
                    do {
                        try self.fanController.resetAppleAutomatic()
                        try self.latchAppleAutomatic()
                    } catch {
                        throw RuntimeTransitionError.failed("Unable to persist requested mode (\(persistenceError)); automatic recovery failed: \(error)")
                    }
                    throw RuntimeTransitionError.failed("Unable to persist requested mode: \(persistenceError)")
                }
                self.config = candidate
                completion(.success(()))
            } catch {
                if self.config.mode != .appleAuto {
                    self.config = previous
                }
                let raw = try? self.fanController.status()
                self.latestStatus = DaemonStatus(
                    timestamp: Date(), mode: self.config.mode,
                    controlTemperature: nil,
                    cpuPeakTemperature: raw.flatMap { Self.peak($0.temperatures, prefixes: ["TC", "Tp"]) },
                    gpuPeakTemperature: raw.flatMap { Self.peak($0.temperatures, prefixes: ["TG", "Tg"]) },
                    hottestSensorTemperature: raw?.temperatures.values.max(),
                    thermalState: Self.thermalStateName(), targetCoolingLevel: nil,
                    fans: raw?.fans ?? [], temperatures: raw?.temperatures ?? [:],
                    hardwareInfo: self.fanController.hardwareInfo, lastError: String(describing: error),
                    recoveryRequired: self.recoveryRequired
                )
                completion(.failure(error))
            }
        }
    }

    func getStatus(completion: @escaping (DaemonStatus) -> Void) {
        // Never wait behind SMC I/O or encode XPC replies on the controller queue.
        completion(latestStatus)
    }

    private func tick() {
        if recoveryRequired {
            do {
                let raw = try fanController.status()
                latestStatus = DaemonStatus(
                    timestamp: Date(), mode: config.mode,
                    controlTemperature: nil, cpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TC", "Tp"]),
                    gpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TG", "Tg"]),
                    hottestSensorTemperature: raw.temperatures.values.max(), thermalState: Self.thermalStateName(),
                    targetCoolingLevel: nil, fans: raw.fans, temperatures: raw.temperatures,
                    hardwareInfo: fanController.hardwareInfo, lastError: lastError,
                    recoveryRequired: true
                )
            } catch { lastError = "Recovery required; read-only status failed: \(error)" }
            return
        }
        do {
            var raw = try fanController.status()
            if let applied = lastAppliedLevel,
               raw.fans.contains(where: { fan in
                   let expected = Double(fan.minRPM) + applied * Double(fan.maxRPM - fan.minRPM)
                   return fan.mode != "manual" || abs(Double(fan.targetRPM) - expected) > 150
               }) {
                var message = "Fan mode or target changed outside CoolerMBP; control paused for recovery."
                if raw.fans.allSatisfy({ $0.mode == "manual" }) {
                    do {
                        try fanController.resetAppleAutomatic()
                        raw = try fanController.status()
                        guard raw.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
                            throw RuntimeTransitionError.failed("fan mode readback did not confirm Apple Automatic")
                        }
                        try latchAppleAutomatic()
                        recoveryRequired = false
                        message = "Unexpected fan target detected; CoolerMBP released manual control and verified Apple Automatic."
                    } catch {
                        recoveryRequired = true
                        message = "Unexpected fan state change; recovery is required: \(error)"
                    }
                } else {
                    // A changed mode may belong to another controller. Leave it alone.
                    recoveryRequired = true
                }
                fputs("CoolerMBP: event=unexpected_fan_state_change recoveryRequired=\(recoveryRequired)\n", stderr)
                lastAppliedLevel = nil
                manualSince = nil
                lastError = message
                latestStatus = DaemonStatus(
                    timestamp: Date(), mode: config.mode,
                    controlTemperature: nil, cpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TC", "Tp"]),
                    gpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TG", "Tg"]),
                    hottestSensorTemperature: raw.temperatures.values.max(), thermalState: Self.thermalStateName(),
                    targetCoolingLevel: nil, fans: raw.fans, temperatures: raw.temperatures,
                    hardwareInfo: fanController.hardwareInfo, lastError: lastError,
                    recoveryRequired: recoveryRequired
                )
                return
            }
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
            var hardwareTransitioned = false

            switch config.mode {
            case .appleAuto:
                missingSensorPolls = 0
                lastValidControlTemperature = nil
                fanResponseFailurePolls = 0
                try fanController.resetAppleAutomatic()
                hardwareTransitioned = true
                lastAppliedLevel = nil
                belowReleaseSince = nil
                manualSince = nil
                recoveryRequired = false

            case .maximum:
                hardwareTransitioned = try apply(level: 1.0)
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
                    hardwareTransitioned = true
                    try latchAppleAutomatic()
                    recoveryRequired = false
                    lastAppliedLevel = nil
                    belowReleaseSince = nil
                    manualSince = nil
                    fanResponseFailurePolls = 0
                    temperatureSmoother.reset()
                    tickError = message
                    raw = try fanController.status()
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
                    hardwareTransitioned = try apply(level: level)
                    targetLevel = level
                } else {
                    if currentlyManual {
                        try fanController.resetAppleAutomatic()
                        hardwareTransitioned = true
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
            if hardwareTransitioned { raw = try fanController.status() }
            latestStatus = makeStatus(raw: raw, thermalState: thermalState, cpuPeak: cpuPeak, gpuPeak: gpuPeak, hottest: hottest, control: controlTemperature, target: targetLevel, error: tickError)
        } catch {
            let operationError = String(describing: error)
            lastError = operationError
            // Failure to read/control sensors is safer when macOS regains authority.
            var restored = false
            var actualStatus: RawThermalStatus?
            do {
                try fanController.resetAppleAutomatic()
                let verified = try fanController.status()
                actualStatus = verified
                guard verified.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
                    throw RuntimeTransitionError.failed("fan mode readback did not confirm Apple Automatic")
                }
                restored = true
            } catch {
                recoveryRequired = true
                lastError = "\(operationError); recovery failed: \(error)"
                actualStatus = try? fanController.status()
            }
            if restored {
                do {
                    try latchAppleAutomatic()
                    recoveryRequired = false
                }
                catch {
                    recoveryRequired = true
                    lastError = "\(lastError ?? operationError); unable to persist safety mode: \(error)"
                }
            }
            lastAppliedLevel = nil
            manualSince = nil
            missingSensorPolls = 0
            lastValidControlTemperature = nil
            fanResponseFailurePolls = 0
            temperatureSmoother.reset()
            recordSafetyFallback(lastError ?? operationError)
            let fans = actualStatus?.fans ?? []
            let temperatures = actualStatus?.temperatures ?? [:]
            latestStatus = DaemonStatus(
                timestamp: Date(), mode: config.mode,
                controlTemperature: nil,
                cpuPeakTemperature: Self.peak(temperatures, prefixes: ["TC", "Tp"]),
                gpuPeakTemperature: Self.peak(temperatures, prefixes: ["TG", "Tg"]),
                hottestSensorTemperature: temperatures.values.max(), thermalState: Self.thermalStateName(),
                targetCoolingLevel: nil, fans: fans, temperatures: temperatures,
                hardwareInfo: fanController.hardwareInfo, lastError: lastError,
                recoveryRequired: recoveryRequired
            )
        }
    }

    private func apply(level: Double) throws -> Bool {
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
            return true
        }
        return false
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
            lastError: error ?? lastError,
            recoveryRequired: recoveryRequired
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

private enum RuntimeTransitionError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let detail): return "Hardware transition failed: \(detail)"
        }
    }
}
