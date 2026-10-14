import Foundation
import CoolerShared
import CoolerSMC

public final class ControllerRuntime {
    private let queue = DispatchQueue(label: "com.superstring.CoolerMBP.controller")
    private let writerLock: SMCWriterLock?
    private let fanController: FanController
    private let policy = CoolingPolicy()
    private var timer: DispatchSourceTimer?
    private var config: DaemonConfig
    private var requestedMode: CoolingMode
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
    private var hardwareVerified = false
    private var ownedFanTargets: [Int: OwnedFanTarget] = [:]

    // A transient SMC sensor gap should not immediately drop manual fan control.
    private static let missingSensorPollLimit = 3
    private static let fanResponseVerificationDelay: TimeInterval = 20
    private static let fanResponseFailurePollLimit = 3

    private let configURL: URL
    private let fanRecoveryURL: URL

    public convenience init() throws {
        let lock = try? SMCWriterLock()
        let controller = try FanController(writeEnabled: lock != nil)
        self.init(
            fanController: controller,
            writerLock: lock,
            configURL: URL(fileURLWithPath: "/Library/Application Support/CoolerMBP/config.json"),
            fanRecoveryURL: FanTransitionRecordFile.defaultURL
        )
    }

    init(fanController: FanController, writerLock: SMCWriterLock? = nil, configURL: URL, fanRecoveryURL: URL? = nil) {
        self.writerLock = writerLock
        self.fanController = fanController
        self.configURL = configURL
        self.fanRecoveryURL = fanRecoveryURL ?? configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        config = Self.loadConfig(from: configURL) ?? DaemonConfig()
        requestedMode = config.mode
        cachedStatus = DaemonStatus(
            timestamp: Date(), mode: requestedMode, persistedMode: config.mode,
            hardwareVerified: false,
            controlTemperature: nil, cpuPeakTemperature: nil, gpuPeakTemperature: nil,
            hottestSensorTemperature: nil, thermalState: Self.thermalStateName(),
            targetCoolingLevel: nil, fans: [], temperatures: [:],
            hardwareInfo: fanController.hardwareInfo, lastError: "Waiting for the first SMC sensor poll."
        )
    }

    public func start() {
        queue.async { [self] in
            do {
                // Never resume a persisted manual request before reconciling
                // hardware state left by a previous daemon instance.
                let raw = try self.reconcileStartupState()
                let candidate = DaemonConfig(mode: .appleAuto)
                try self.saveConfig(candidate)
                self.config = candidate
                self.requestedMode = .appleAuto
                self.hardwareVerified = true
                self.recoveryRequired = false
                self.ownedFanTargets.removeAll()
                self.lastError = nil
                self.publish(raw, error: nil)
                _ = self.tick()
            } catch {
                self.lastError = "Startup recovery required: \(error)"
                self.recoveryRequired = true
                self.hardwareVerified = false
                self.requestedMode = .appleAuto
                self.recordSafetyFallback(self.lastError!)
                self.publish(try? self.fanController.status(), error: self.lastError)
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in _ = self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func shutdown() {
        queue.sync {
            timer?.cancel()
            timer = nil
            do {
                let raw = try fanController.status()
                guard !raw.fans.contains(where: { $0.mode == "manual" }) || hasVerifiedFanOwnership(raw.fans) else {
                    throw RuntimeTransitionError.failed("Refusing shutdown restore because manual fan ownership is unknown")
                }
                _ = try restoreAppleAutomatic()
            }
            catch { fputs("CoolerMBP: failed to restore Apple fan control: \(error)\n", stderr) }
        }
    }

    public func setMode(_ mode: CoolingMode, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if mode == .appleAuto {
                self.requestedMode = .appleAuto
                do {
                    let current = try self.fanController.status()
                    guard !current.fans.contains(where: { $0.mode == "manual" }) || self.hasVerifiedFanOwnership(current.fans) else {
                        throw RuntimeTransitionError.failed("Manual fan ownership is unknown. Verify that no other fan controller is active, then run sudo /usr/local/sbin/coolermbpsmc recover-unknown-fans to explicitly return fans to macOS.")
                    }
                    let raw = try self.restoreAppleAutomatic()
                    let candidate = DaemonConfig(mode: .appleAuto)
                    self.hardwareVerified = true
                    self.recoveryRequired = false
                    self.ownedFanTargets.removeAll()
                    self.resetControlState()
                    do {
                        try self.saveConfig(candidate)
                        self.config = candidate
                        self.lastError = nil
                        self.publish(raw, error: nil)
                        completion(.success(()))
                    } catch {
                        self.lastError = "Configuration persistence failed after verified Apple Automatic recovery: \(error)"
                        self.publish(raw, error: self.lastError)
                        completion(.failure(RuntimeTransitionError.failed(self.lastError!)))
                    }
                } catch {
                    self.recoveryRequired = true
                    self.hardwareVerified = false
                    self.lastError = "Apple Automatic recovery failed: \(error)"
                    self.publish(try? self.fanController.status(), error: self.lastError)
                    completion(.failure(error))
                }
                return
            }

            guard !self.recoveryRequired else {
                let error = RuntimeTransitionError.failed("Recovery is required; manual modes are disabled")
                self.lastError = String(describing: error)
                self.publish(try? self.fanController.status(), error: self.lastError)
                completion(.failure(error))
                return
            }

            self.requestedMode = mode
            self.resetControlState()
            self.lastError = nil
            switch self.tick() {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                do {
                    let raw = try self.fanController.status()
                    try self.verifyRequestedMode(mode, raw: raw)
                    self.hardwareVerified = true
                    self.recoveryRequired = false
                    let candidate = DaemonConfig(mode: mode)
                    do {
                        try self.saveConfig(candidate)
                        self.config = candidate
                        self.lastError = nil
                        self.publish(raw, error: nil)
                        completion(.success(()))
                    } catch {
                        let persistenceError = error
                        self.requestedMode = .appleAuto
                        do {
                            let restored = try self.restoreAppleAutomatic()
                            self.hardwareVerified = true
                            self.recoveryRequired = false
                            self.ownedFanTargets.removeAll()
                            self.resetControlState()
                            do {
                                let automatic = DaemonConfig(mode: .appleAuto)
                                try self.saveConfig(automatic)
                                self.config = automatic
                                self.lastError = "Configuration persistence failed; hardware was restored to Apple Automatic: \(persistenceError)"
                            } catch {
                                self.lastError = "Configuration persistence failed; hardware is verified Apple Automatic but persisted mode remains \(self.config.mode.rawValue): \(persistenceError); \(error)"
                            }
                            self.publish(restored, error: self.lastError)
                        } catch {
                            self.recoveryRequired = true
                            self.hardwareVerified = false
                            self.lastError = "Configuration persistence failed and Apple Automatic recovery failed: \(persistenceError); \(error)"
                            self.publish(try? self.fanController.status(), error: self.lastError)
                        }
                        completion(.failure(RuntimeTransitionError.failed(self.lastError ?? "Configuration persistence failed")))
                    }
                } catch {
                    self.recoveryRequired = true
                    self.hardwareVerified = false
                    self.requestedMode = .appleAuto
                    self.lastError = "Hardware verification failed: \(error)"
                    self.publish(try? self.fanController.status(), error: self.lastError)
                    completion(.failure(error))
                }
            }
        }
    }

    public func getStatus(completion: @escaping (DaemonStatus) -> Void) {
        // Never wait behind SMC I/O or encode XPC replies on the controller queue.
        completion(latestStatus)
    }

    @discardableResult
    func pollForTesting() -> Result<Void, Error> {
        queue.sync { tick() }
    }

    func startupRecoveryForTesting() -> Result<Void, Error> {
        queue.sync {
            do {
                let raw = try reconcileStartupState()
                let candidate = DaemonConfig(mode: .appleAuto)
                try saveConfig(candidate)
                config = candidate
                requestedMode = .appleAuto
                hardwareVerified = true
                recoveryRequired = false
                ownedFanTargets.removeAll()
                lastError = nil
                publish(raw, error: nil)
                return .success(())
            } catch {
                requestedMode = .appleAuto
                recoveryRequired = true
                hardwareVerified = false
                lastError = "Startup recovery required: \(error)"
                publish(try? fanController.status(), error: lastError)
                return .failure(error)
            }
        }
    }

    private func tick() -> Result<Void, Error> {
        if recoveryRequired {
            do {
                let raw = try fanController.status()
                latestStatus = DaemonStatus(
                    timestamp: Date(), mode: requestedMode, persistedMode: config.mode,
                    hardwareVerified: hardwareVerified,
                    controlTemperature: nil, cpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TC", "Tp"]),
                    gpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TG", "Tg"]),
                    hottestSensorTemperature: raw.temperatures.values.max(), thermalState: Self.thermalStateName(),
                    targetCoolingLevel: nil, fans: raw.fans, temperatures: raw.temperatures,
                    hardwareInfo: fanController.hardwareInfo, lastError: lastError,
                    recoveryRequired: true
                )
            } catch { lastError = "Recovery required; read-only status failed: \(error)" }
            return .failure(RuntimeTransitionError.failed(lastError ?? "Recovery is required"))
        }
        do {
            var raw = try fanController.status()
            let hasManualFan = raw.fans.contains { $0.mode == "manual" }
            if (hasManualFan && !hasVerifiedFanOwnership(raw.fans)) || (!hasManualFan && lastAppliedLevel != nil) {
                recoveryRequired = true
                hardwareVerified = false
                lastAppliedLevel = nil
                manualSince = nil
                lastError = "Fan state differs from CoolerMBP's last verified targets; possible external ownership, control paused."
                fputs("CoolerMBP: event=unexpected_fan_state_change action=read_only_recovery_required\n", stderr)
                publish(raw, error: lastError)
                return .failure(RuntimeTransitionError.failed(lastError!))
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

            switch requestedMode {
            case .appleAuto:
                missingSensorPolls = 0
                lastValidControlTemperature = nil
                fanResponseFailurePolls = 0
                raw = try restoreAppleAutomatic()
                hardwareTransitioned = true
                lastAppliedLevel = nil
                ownedFanTargets.removeAll()
                belowReleaseSince = nil
                manualSince = nil
                recoveryRequired = false
                hardwareVerified = true

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
                        return .success(())
                    }
                    let message = "No valid thermal sensors were found; returned fan control to macOS."
                    recordSafetyFallback(message)
                    raw = try restoreAppleAutomatic()
                    hardwareTransitioned = true
                    requestedMode = .appleAuto
                    try latchAppleAutomatic()
                    recoveryRequired = false
                    hardwareVerified = true
                    ownedFanTargets.removeAll()
                    lastAppliedLevel = nil
                    belowReleaseSince = nil
                    manualSince = nil
                    fanResponseFailurePolls = 0
                    temperatureSmoother.reset()
                    tickError = message
                    raw = try fanController.status()
                    latestStatus = makeStatus(raw: raw, thermalState: thermalState, cpuPeak: cpuPeak, gpuPeak: gpuPeak, hottest: hottest, control: nil, target: nil, error: tickError)
                    return .failure(RuntimeTransitionError.failed(message))
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
                        raw = try restoreAppleAutomatic()
                        hardwareTransitioned = true
                    }
                    lastAppliedLevel = nil
                    manualSince = nil
                    targetLevel = nil
                }
            }

            if let tickError {
                lastError = tickError
            } else if requestedMode != .appleAuto {
                lastError = nil
            }
            if hardwareTransitioned { raw = try fanController.status() }
            hardwareVerified = true
            latestStatus = makeStatus(raw: raw, thermalState: thermalState, cpuPeak: cpuPeak, gpuPeak: gpuPeak, hottest: hottest, control: controlTemperature, target: targetLevel, error: tickError)
            return .success(())
        } catch {
            let operationError = String(describing: error)
            lastError = operationError
            var actualStatus: RawThermalStatus?
            do {
                let observed = try fanController.status()
                actualStatus = observed
                let hasManualFan = observed.fans.contains { $0.mode == "manual" }
                guard !hasManualFan || hasVerifiedFanOwnership(observed.fans) else {
                    throw RuntimeTransitionError.failed("manual fan ownership is unknown; refusing recovery writes")
                }
                let verified = try restoreAppleAutomatic()
                actualStatus = verified
                requestedMode = .appleAuto
                hardwareVerified = true
                recoveryRequired = false
                do {
                    try latchAppleAutomatic()
                    lastError = operationError
                } catch {
                    lastError = "\(operationError); hardware is verified Apple Automatic but persistence failed: \(error)"
                }
            } catch {
                recoveryRequired = true
                hardwareVerified = false
                lastError = "\(operationError); recovery failed: \(error)"
                requestedMode = .appleAuto
                actualStatus = actualStatus ?? (try? fanController.status())
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
            let raw = RawThermalStatus(fans: fans, temperatures: temperatures)
            latestStatus = makeStatus(raw: raw, thermalState: Self.thermalStateName(),
                cpuPeak: Self.peak(temperatures, prefixes: ["TC", "Tp"]),
                gpuPeak: Self.peak(temperatures, prefixes: ["TG", "Tg"]),
                hottest: temperatures.values.max(), control: nil, target: nil, error: lastError)
            return .failure(error)
        }
    }

    private func apply(level: Double) throws -> Bool {
        let clamped = min(max(level, 0), 1)
        let needsRefresh = Date().timeIntervalSince(lastApplyDate) >= 10
        if lastAppliedLevel == nil || abs((lastAppliedLevel ?? 0) - clamped) >= 0.025 || needsRefresh {
            let before = try fanController.status()
            let entries = before.fans.map { fan in
                let target = Double(fan.minRPM) + clamped * Double(fan.maxRPM - fan.minRPM)
                return FanTransitionEntry(
                    index: fan.index,
                    modeKey: fan.modeKey ?? "",
                    previousMode: fan.mode,
                    previousTargetRPM: fan.targetRPM,
                    targetRPM: Int(target.rounded())
                )
            }
            guard entries.allSatisfy({ !$0.modeKey.isEmpty }) else {
                throw RuntimeTransitionError.failed("Fan mode key could not be recorded before control transition")
            }
            try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: entries), to: fanRecoveryURL)
            try fanController.setCoolingLevel(clamped)
            let raw = try fanController.status()
            try verifyRequestedMode(.maximum, raw: raw, level: clamped)
            try FanTransitionRecordFile.write(FanTransitionRecord(phase: .active, fans: entries), to: fanRecoveryURL)
            ownedFanTargets = Dictionary(uniqueKeysWithValues: raw.fans.map {
                ($0.index, OwnedFanTarget(modeKey: $0.modeKey, targetRPM: $0.targetRPM))
            })
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
            timestamp: Date(), mode: requestedMode, persistedMode: config.mode,
            hardwareVerified: hardwareVerified,
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

    private func publish(_ raw: RawThermalStatus?, error: String?) {
        let raw = raw ?? RawThermalStatus(fans: [], temperatures: [:])
        latestStatus = DaemonStatus(
            timestamp: Date(), mode: requestedMode, persistedMode: config.mode,
            hardwareVerified: hardwareVerified,
            controlTemperature: nil,
            cpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TC", "Tp"]),
            gpuPeakTemperature: Self.peak(raw.temperatures, prefixes: ["TG", "Tg"]),
            hottestSensorTemperature: raw.temperatures.values.max(),
            thermalState: Self.thermalStateName(), targetCoolingLevel: lastAppliedLevel,
            fans: raw.fans, temperatures: raw.temperatures,
            hardwareInfo: fanController.hardwareInfo, lastError: error,
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

    private func resetControlState() {
        lastAppliedLevel = nil
        lastApplyDate = .distantPast
        belowReleaseSince = nil
        manualSince = nil
        missingSensorPolls = 0
        lastValidControlTemperature = nil
        fanResponseFailurePolls = 0
        temperatureSmoother.reset()
    }

    private func restoreAppleAutomatic() throws -> RawThermalStatus {
        let current = try fanController.status()
        guard !current.fans.contains(where: { $0.mode == "manual" }) || hasVerifiedFanOwnership(current.fans) else {
            throw RuntimeTransitionError.failed("Manual fan ownership is unknown; refusing automatic restoration")
        }
        try fanController.resetAppleAutomatic()
        let raw = try fanController.status()
        guard raw.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
            throw RuntimeTransitionError.failed("fan mode readback did not confirm Apple Automatic")
        }
        try FanTransitionRecordFile.clear(at: fanRecoveryURL)
        ownedFanTargets.removeAll()
        lastAppliedLevel = nil
        return raw
    }

    private func reconcileStartupState() throws -> RawThermalStatus {
        try restoreAppleAutomatic()
    }

    private func ownsCurrentManualState(_ fans: [FanReading]) -> Bool {
        guard !fans.isEmpty, fans.count == ownedFanTargets.count else { return false }
        return fans.allSatisfy { fan in
            guard let owned = ownedFanTargets[fan.index] else { return false }
            return fan.mode == "manual" && fan.modeKey == owned.modeKey && abs(fan.targetRPM - owned.targetRPM) <= 100
        }
    }

    private func hasVerifiedFanOwnership(_ fans: [FanReading]) -> Bool {
        if ownsCurrentManualState(fans) { return true }
        guard case .record(let record) = FanTransitionRecordFile.read(from: fanRecoveryURL) else { return false }
        return record.matches(fans)
    }

    private func verifyRequestedMode(_ mode: CoolingMode, raw: RawThermalStatus, level: Double? = nil) throws {
        switch mode {
        case .appleAuto:
            guard raw.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
                throw RuntimeTransitionError.failed("fan mode readback did not confirm Apple Automatic")
            }
        case .maximum:
            guard !raw.fans.isEmpty, raw.fans.allSatisfy({ $0.mode == "manual" }) else {
                throw RuntimeTransitionError.failed("fan mode readback did not confirm manual control")
            }
            if let level {
                for fan in raw.fans {
                    let target = Int((Double(fan.minRPM) + level * Double(fan.maxRPM - fan.minRPM)).rounded())
                    guard abs(fan.targetRPM - target) <= 100 else {
                        throw RuntimeTransitionError.failed("fan \(fan.index) target readback does not match requested level")
                    }
                }
            }
        case .coolSurface:
            guard !raw.fans.isEmpty, raw.fans.allSatisfy({ ["manual", "auto", "system"].contains($0.mode) }) else {
                throw RuntimeTransitionError.failed("fan mode readback returned an unsupported mode")
            }
        }
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

private struct OwnedFanTarget {
    let modeKey: String?
    let targetRPM: Int
}
