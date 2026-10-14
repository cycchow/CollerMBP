import Foundation
import Darwin
import CoolerShared

public enum FanControllerError: Error, CustomStringConvertible {
    case connectionFailed
    case readFailed(String)
    case writeFailed(String)
    case unlockFailed(String)
    case invalidFanLimits(Int)
    case invalidFanCount(Int)
    case noFans
    case fanNotResponding(Int, Int, Int)
    case recoveryFailed([String])

    public var description: String {
        switch self {
        case .connectionFailed: return "Unable to connect to AppleSMC"
        case .readFailed(let key): return "Unable to read SMC key \(key)"
        case .writeFailed(let key): return "Unable to write SMC key \(key)"
        case .unlockFailed(let detail): return "Fan-control unlock failed: \(detail)"
        case .invalidFanLimits(let index): return "Fan \(index) reported invalid min/max RPM limits"
        case .invalidFanCount(let count): return "SMC reported unsupported fan count \(count)"
        case .noFans: return "No fans were reported by SMC"
        case .fanNotResponding(let index, let actual, let target):
            return "Fan \(index) is not responding (actual \(actual) RPM, target \(target) RPM)"
        case .recoveryFailed(let failures):
            return "Unable to restore Apple fan control: \(failures.joined(separator: ", "))"
        }
    }
}

public struct RawThermalStatus {
    public let fans: [FanReading]
    public let temperatures: [String: Double]

    public init(fans: [FanReading], temperatures: [String: Double]) {
        self.fans = fans
        self.temperatures = temperatures
    }
}

struct FanControllerTiming {
    let manualVerificationTimeout: TimeInterval
    let rollbackTimeout: TimeInterval
    let automaticStabilityWindow: TimeInterval
    let pollInterval: TimeInterval

    static let production = FanControllerTiming(
        manualVerificationTimeout: 2,
        rollbackTimeout: 5,
        automaticStabilityWindow: 1,
        pollInterval: 0.1
    )
    static let testing = FanControllerTiming(
        manualVerificationTimeout: 0.12,
        rollbackTimeout: 0.4,
        automaticStabilityWindow: 0.08,
        pollInterval: 0.005
    )
}

public final class FanController {
    private let smc: any SMCTransport
    private let recoveryURL: URL?
    private let writeEnabled: Bool
    private let modelIdentifier: String?
    private let timing: FanControllerTiming
    private var ownsFtst: Bool
    private var manualStrategy = "notApplicable"
    private var lastTransitionDate: Date?
    private var modeKeys: [Int: String] = [:]
    private var attemptedManualModeKeys: [Int: String] = [:]

    private static let fanCountKey = "FNum"
    private static let forceTestKey = "Ftst"
    private static let actualTemplate = "F%dAc"
    private static let targetTemplate = "F%dTg"
    private static let minTemplate = "F%dMn"
    private static let maxTemplate = "F%dMx"
    private static let modeUpperTemplate = "F%dMd"
    private static let modeLowerTemplate = "F%dmd"

    // Known Apple-Silicon thermal keys. Missing keys are simply skipped.
    private static let floatTemperatureKeys = [
        "TCDX", "TCHP", "TCMb",
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
        "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
        "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR", "TPDX",
        "TH0x", "TH0A", "TH0B", "TAOL", "TA0P", "TS0P", "TB0T"
    ]

    private static let ioftTemperatureKeys = ["TG0B", "TG0H", "TG0V"]

    private static func hardwareModelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    public init(writeEnabled: Bool = true) throws {
        guard let connection = SMCConnection() else { throw FanControllerError.connectionFailed }
        self.smc = connection
        self.writeEnabled = writeEnabled
        self.modelIdentifier = Self.hardwareModelIdentifier()
        self.timing = .production
        self.recoveryURL = URL(fileURLWithPath: "/Library/Application Support/CoolerMBP/recovery.json")
        self.ownsFtst = Self.readOwnership(from: recoveryURL)
    }

    init(
        smc: any SMCTransport,
        recoveryURL: URL? = nil,
        writeEnabled: Bool = true,
        modelIdentifier: String? = "TestModel",
        timing: FanControllerTiming = .testing
    ) {
        self.smc = smc
        self.recoveryURL = recoveryURL
        self.writeEnabled = writeEnabled
        self.modelIdentifier = modelIdentifier
        self.timing = timing
        self.ownsFtst = Self.readOwnership(from: recoveryURL)
    }

    public var hardwareInfo: String {
        let capability = discoverFtst()
        let value: String
        if case .available = capability {
            let ftst = smc.readKey(Self.forceTestKey)
            value = ftst.success && ftst.size == 1 && ftst.type == "ui8 " && ftst.bytes.count == 1
                ? String(ftst.bytes[0]) : "read-error"
        } else {
            value = capability.diagnostic
        }
        let transition = lastTransitionDate.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
        let ownership = ftstOwnership(for: capability)
        let recoveryRequired = ownership == "unknown" || ownership.hasPrefix("read-error") || ownership == "unsupported-format"
        return "Ftst=\(capability.diagnostic):\(value), ownership=\(ownership), strategy=\(manualStrategy), lastTransition=\(transition), recoveryRequired=\(recoveryRequired)"
    }

    public var ftstAvailability: String {
        discoverFtst().diagnostic
    }

    public var ftstOwnership: String {
        ftstOwnership(for: discoverFtst())
    }

    private func ftstOwnership(for capability: FtstCapability) -> String {
        switch capability {
        case .absent: return "unavailable"
        case .unsupportedFormat: return "unsupported-format"
        case .readError(let failure): return "read-error(\(failure))"
        case .available: break
        }
        let result = smc.readKey(Self.forceTestKey)
        guard result.success, result.size == 1, result.type == "ui8 ", result.bytes.count == 1 else { return "read-error(value)" }
        if result.bytes[0] == 0 { return "inactive" }
        if result.bytes[0] != 1 { return "unsupported-value(\(result.bytes[0]))" }
        return ownsFtst ? "owned" : "unknown"
    }

    private func discoverFtst() -> FtstCapability {
        switch smc.getKeyInfo(Self.forceTestKey) {
        case .absent:
            return .absent
        case .failure(let error):
            return .readError(error)
        case .available(let size, let type):
            guard size == 1, type == "ui8 " else { return .unsupportedFormat(size: size, type: type) }
            return .available
        }
    }

    public func status() throws -> RawThermalStatus {
        let count = try fanCount()
        var fans: [FanReading] = []
        for index in 0..<count {
            fans.append(try fanInfo(index))
        }

        var temperatures: [String: Double] = [:]
        for key in Self.floatTemperatureKeys {
            let result = smc.readKey(key)
            guard result.success, result.size == 4, result.type == "flt ", result.bytes.count == 4 else { continue }
            let value = Double(Self.floatValue(result.bytes))
            if value > 0, value < 150 { temperatures[key] = (value * 10).rounded() / 10 }
        }

        for key in Self.ioftTemperatureKeys {
            let result = smc.readKey(key)
            guard result.success, result.size == 8, result.type == "ioft", result.bytes.count == 8 else { continue }
            let value = Double(Self.ioftValue(result.bytes))
            if value > 0, value < 150 { temperatures[key] = (value * 10).rounded() / 10 }
        }

        return RawThermalStatus(fans: fans, temperatures: temperatures)
    }

    public func setCoolingLevel(_ level: Double) throws {
        try setCoolingLevel(level, onManualModeWriteAttempt: nil)
    }

    public func setCoolingLevel(_ level: Double, onManualModeWriteAttempt: ((Int, String) throws -> Void)?) throws {
        guard writeEnabled else { throw FanControllerError.writeFailed("SMC writer lock unavailable; controller is read-only") }
        let ftst = discoverFtst()
        switch ftst {
        case .absent:
            guard !ownsFtst else { throw FanControllerError.unlockFailed("Ftst was previously owned but is now absent") }
        case .available:
            let ownership = ftstOwnership(for: ftst)
            guard ownership == "inactive" || ownership == "owned" else {
                throw FanControllerError.unlockFailed("Ftst state is not safe for manual control: \(ownership)")
            }
        case .unsupportedFormat, .readError:
            throw FanControllerError.unlockFailed("Ftst discovery is uncertain: \(ftst.diagnostic)")
        }
        let clamped = min(max(level, 0), 1)
        let count = try fanCount()
        let infos = try (0..<count).map(fanInfo)

        for fan in infos where fan.maxRPM <= fan.minRPM || fan.minRPM <= 0 {
            throw FanControllerError.invalidFanLimits(fan.index)
        }
        if let reason = manualTransitionRestriction(for: infos) {
            logEvent("manual_transition_unsupported", "reason=\(reason)")
            throw FanControllerError.unlockFailed(reason)
        }

        do {
            if infos.contains(where: { $0.mode != "manual" }) {
                logEvent("manual_request", "level=\(clamped)")
                try enterManualMode(infos, onManualModeWriteAttempt: onManualModeWriteAttempt)
            }

            let targets = infos.map { fan -> (fan: FanReading, key: String, rpm: Int, bytes: [UInt8]) in
                let target = Double(fan.minRPM) + clamped * Double(fan.maxRPM - fan.minRPM)
                let key = Self.key(Self.targetTemplate, fan: fan.index)
                return (fan, key, Int(target.rounded()), Self.floatBytes(Float(target)))
            }

            for target in targets {
                let deadline = Date().addingTimeInterval(2)
                var written = false
                repeat {
                    if smc.writeKey(target.key, bytes: target.bytes).success {
                        written = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                } while Date() < deadline
                guard written else {
                    let key = target.key
                    logEvent("target_write_failed", "key=\(key)")
                    throw FanControllerError.writeFailed(key)
                }
                logEvent("target_written", "key=\(target.key) rpm=\(target.rpm)")
            }

            var pending = targets
            let verificationDeadline = Date().addingTimeInterval(2)
            repeat {
                pending.removeAll { target in
                    guard let applied = try? fanInfo(target.fan.index) else { return false }
                    return applied.mode == "manual" && abs(applied.targetRPM - target.rpm) <= 100
                }
                if pending.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < verificationDeadline

            if let failed = pending.first {
                let readback = (try? fanInfo(failed.fan.index)).map { "mode=\($0.mode) targetRPM=\($0.targetRPM)" } ?? "readback=unavailable"
                logEvent("target_rpm_readback", "fan=\(failed.fan.index) key=\(failed.key) expectedRPM=\(failed.rpm) \(readback)")
                throw FanControllerError.writeFailed("\(failed.key) verification")
            }
            for target in targets {
                let applied = try fanInfo(target.fan.index)
                logEvent("target_rpm_readback", "fan=\(target.fan.index) key=\(target.key) mode=\(applied.mode) targetRPM=\(applied.targetRPM) expectedRPM=\(target.rpm)")
            }
        } catch let operationError {
            logEvent("rollback_initiated", "reason=\(operationError)")
            do { try resetAppleAutomatic() }
            catch let recoveryError {
                throw FanControllerError.recoveryFailed([
                    "operation: \(operationError)",
                    "recovery: \(recoveryError)"
                ])
            }
            throw operationError
        }
    }

    public func manualTransitionRestriction(for fans: [FanReading]) -> String? {
        if modelIdentifier == "Mac14,9" {
            return "manual control is disabled on Mac14,9: mode writes can activate before a nonzero target is established"
        }
        if let fan = fans.first(where: { $0.mode != "manual" && $0.targetRPM <= 0 }) {
            return "fan \(fan.index) modeKey=\(fan.modeKey ?? "unknown") mode=\(fan.mode) targetRPM=\(fan.targetRPM); refusing manual mode because nonzero target-before-mode behavior is unverified"
        }
        return nil
    }

    public func setMaximum() throws {
        try setCoolingLevel(1.0)
    }

    public func resetAppleAutomatic(
        allowUnknownFtstRelease: Bool = false,
        attemptedFanModeKeys: [Int: String] = [:]
    ) throws {
        guard writeEnabled else { throw FanControllerError.recoveryFailed(["SMC writer lock unavailable; controller is read-only"]) }
        let count = try fanCount()
        // Read and validate the full recovery state before the first write.
        let fans = try (0..<count).map(fanInfo)
        for fan in fans where fan.mode != "auto" && fan.mode != "system" && fan.mode != "manual" {
            throw FanControllerError.recoveryFailed(["fan \(fan.index) has unsupported mode \(fan.mode)"])
        }
        var ftstValue: UInt8?
        switch discoverFtst() {
        case .absent:
            guard !ownsFtst else {
                throw FanControllerError.recoveryFailed(["Ftst was previously owned but is now confirmed absent"])
            }
        case .available:
            let ftst = smc.readKey(Self.forceTestKey)
            guard ftst.success, ftst.size == 1, ftst.type == "ui8 ", ftst.bytes.count == 1 else {
                throw FanControllerError.recoveryFailed(["Ftst ownership cannot be verified"])
            }
            ftstValue = ftst.bytes[0]
            guard ftst.bytes[0] <= 1 else {
                throw FanControllerError.recoveryFailed(["Ftst has unsupported active value \(ftst.bytes[0])"])
            }
            if ftst.bytes[0] == 1 && !ownsFtst && !allowUnknownFtstRelease {
                throw FanControllerError.recoveryFailed(["Ftst is active with unknown ownership"])
            }
        case .unsupportedFormat(let size, let type):
            throw FanControllerError.recoveryFailed(["Ftst has unsupported format size=\(size) type=\(type)"])
        case .readError(let failure):
            throw FanControllerError.recoveryFailed(["Ftst discovery failed: \(failure)"])
        }

        var failures: [String] = []
        var reconciliationNeeded = false
        var changedFanMode = false
        var restoreModeKeys = self.attemptedManualModeKeys
        for (index, key) in attemptedFanModeKeys {
            guard let fan = fans.first(where: { $0.index == index }), fan.modeKey == key else {
                throw FanControllerError.recoveryFailed(["fan transition record does not match fan \(index) mode key"])
            }
            restoreModeKeys[index] = key
        }
        for fan in fans where fan.mode == "manual" {
            restoreModeKeys[fan.index] = fan.modeKey!
        }
        for (index, modeKey) in restoreModeKeys.sorted(by: { $0.key < $1.key }) {
            guard fans.contains(where: { $0.index == index && $0.modeKey == modeKey }) else {
                failures.append("fan \(index) mode key does not match rollback state")
                continue
            }
            reconciliationNeeded = true
            let observed = fans.first(where: { $0.index == index })!.mode
            logEvent("rollback_mode_write_attempted", "fan=\(index) modeKey=\(modeKey) mode=\(observed) targetRPM=\(fans.first(where: { $0.index == index })!.targetRPM) requested=auto")
            let result = smc.writeKey(modeKey, bytes: [0])
            if !result.success {
                logEvent("rollback_mode_write_rejected", "fan=\(index) modeKey=\(modeKey) mode=\(observed) targetRPM=\(fans.first(where: { $0.index == index })!.targetRPM)")
                failures.append("\(modeKey) write rejected (kernel=\(String(describing: result.kernelReturn)), firmware=\(String(describing: result.firmwareResult)))")
            } else {
                changedFanMode = true
                logEvent("rollback_mode_write_accepted", "fan=\(index) modeKey=\(modeKey) mode=\(observed) targetRPM=\(fans.first(where: { $0.index == index })!.targetRPM)")
            }
        }
        var fansVerified = false
        var stableSince: Date?
        var rollbackRetries: Set<Int> = []
        var rollbackReadFailures: Set<Int> = []
        let stabilizationWindow = restoreModeKeys.isEmpty ? 0 : timing.automaticStabilityWindow
        let rollbackDeadline = Date().addingTimeInterval(timing.rollbackTimeout)
        repeat {
            var allAutomatic = true
            for fan in fans {
                do {
                    let mode = try readFanMode(fan.index)
                    if mode == "auto" || mode == "system" { continue }
                    allAutomatic = false
                    if mode == "manual", let key = restoreModeKeys[fan.index], !rollbackRetries.contains(fan.index) {
                        rollbackRetries.insert(fan.index)
                        let targetRPM = (try? fanInfo(fan.index).targetRPM).map(String.init) ?? "unavailable"
                        logEvent("rollback_delayed_manual_detected", "fan=\(fan.index) modeKey=\(key) mode=\(mode) targetRPM=\(targetRPM)")
                        let result = smc.writeKey(key, bytes: [0])
                        if !result.success {
                            failures.append("\(key) delayed rollback write rejected")
                            logEvent("rollback_mode_write_rejected", "fan=\(fan.index) modeKey=\(key) mode=\(mode) delayed=true")
                        } else {
                            logEvent("rollback_mode_write_accepted", "fan=\(fan.index) modeKey=\(key) mode=\(mode) delayed=true")
                        }
                    } else if mode != "manual" {
                        failures.append("fan \(fan.index) has unsupported rollback mode \(mode)")
                    }
                } catch {
                    allAutomatic = false
                    if rollbackReadFailures.insert(fan.index).inserted {
                        logEvent("rollback_mode_readback_unavailable", "fan=\(fan.index) modeKey=\(fan.modeKey ?? "unknown") error=\(error)")
                    }
                }
            }
            if allAutomatic {
                if stableSince == nil { stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) >= stabilizationWindow {
                    fansVerified = true
                    break
                }
            } else {
                stableSince = nil
            }
            if !failures.isEmpty { break }
            Thread.sleep(forTimeInterval: timing.pollInterval)
        } while Date() < rollbackDeadline
        if !fansVerified {
            failures.append("fan mode restoration did not remain verified Apple Automatic for the stabilization window")
            logEvent("uncertain_hardware_state", "phase=rollback fansVerified=false pendingManualWrites=\(restoreModeKeys.count)")
        } else {
            logEvent("rollback_mode_verification", "fans=\(fans.count) state=stable_automatic window=\(stabilizationWindow)")
        }
        if let ftstValue {
            if ftstValue == 1 && !ownsFtst {
                reconciliationNeeded = true
                if fansVerified && failures.isEmpty && allowUnknownFtstRelease {
                    logEvent("explicit_unknown_ftst_recovery", "admin_requested=true")
                    let result = smc.writeKey(Self.forceTestKey, bytes: [0])
                    if !result.success { failures.append("explicit Ftst release rejected") }
                }
            } else if ftstValue == 1 && ownsFtst && fansVerified && failures.isEmpty {
                reconciliationNeeded = true
                logEvent("automatic_restore_requested", "releasing_owned_ftst=true")
                let result = smc.writeKey(Self.forceTestKey, bytes: [0])
                if !result.success { failures.append("Ftst release rejected") }
            }
            if ftstValue == 0 || (fansVerified && (ownsFtst || allowUnknownFtstRelease)) {
                let verify = smc.readKey(Self.forceTestKey)
                if !verify.success || verify.size != 1 || verify.type != "ui8 " || verify.bytes != [0] {
                    failures.append("Ftst release verification")
                } else if ownsFtst {
                    do {
                        try persistOwnership(false)
                        ownsFtst = false
                        manualStrategy = "notApplicable"
                        lastTransitionDate = Date()
                        logEvent("ftst_released", "verified=0 owner=CoolerMBP")
                    } catch { failures.append("recovery metadata: \(error)") }
                } else {
                    // A zero flag that CoolerMBP did not set needs no ownership mutation.
                }
            }
        }
        if !failures.isEmpty {
            logEvent("ownership_record_retained", "reason=automatic_restore_unverified")
            logEvent("automatic_restore_failed", failures.joined(separator: ";"))
            throw FanControllerError.recoveryFailed(failures)
        }
        if changedFanMode {
            manualStrategy = "notApplicable"
            lastTransitionDate = Date()
        }
        if fansVerified { attemptedManualModeKeys.removeAll() }
        if reconciliationNeeded { logEvent("automatic_restore_verified", "fans=\(count), ftst=\(ftstOwnership)") }
    }

    public static func verifyFanResponse(_ fans: [FanReading]) throws {
        for fan in fans where fan.mode == "manual" && fan.targetRPM > fan.minRPM + 300 {
            let minimumExpected = max(fan.minRPM, fan.targetRPM - 500)
            if fan.actualRPM < minimumExpected {
                throw FanControllerError.fanNotResponding(fan.index, fan.actualRPM, fan.targetRPM)
            }
        }
    }

    private func fanCount() throws -> Int {
        let result = smc.readKey(Self.fanCountKey)
        guard result.success, result.size == 1, result.type == "ui8 ", result.bytes.count == 1 else {
            throw FanControllerError.readFailed(Self.fanCountKey)
        }
        let first = result.bytes[0]
        let count = Int(first)
        guard count > 0 else { throw FanControllerError.noFans }
        guard count <= 10 else { throw FanControllerError.invalidFanCount(count) }
        return count
    }

    private func fanInfo(_ index: Int) throws -> FanReading {
        let actual = readFanFloat(index, template: Self.actualTemplate)
        let target = readFanFloat(index, template: Self.targetTemplate)
        let minimum = readFanFloat(index, template: Self.minTemplate)
        let maximum = readFanFloat(index, template: Self.maxTemplate)
        let modeKey = try modeKey(for: index)
        guard [actual, target, minimum, maximum].allSatisfy(\.isFinite) else {
            throw FanControllerError.readFailed("fan \(index) RPM keys (invalid type, size, or value)")
        }
        let mode = try readFanMode(index)

        return FanReading(
            index: index,
            actualRPM: Int(actual.rounded()),
            targetRPM: Int(target.rounded()),
            minRPM: Int(minimum.rounded()),
            maxRPM: Int(maximum.rounded()),
            mode: mode,
            modeKey: modeKey
        )
    }

    private func readFanMode(_ index: Int) throws -> String {
        let key = try modeKey(for: index)
        let result = smc.readKey(key)
        guard result.success, result.size == 1, result.type == "ui8 ", result.bytes.count == 1 else {
            throw FanControllerError.readFailed(key)
        }
        switch result.bytes[0] {
        case 0: return "auto"
        case 1: return "manual"
        case 3: return "system"
        default: throw FanControllerError.readFailed("\(key) invalid mode value \(result.bytes[0])")
        }
    }

    private func enterManualMode(_ fans: [FanReading], onManualModeWriteAttempt: ((Int, String) throws -> Void)?) throws {
        for fan in fans where fan.mode != "manual" {
            let key = try modeKey(for: fan.index)
            attemptedManualModeKeys[fan.index] = key
            try onManualModeWriteAttempt?(fan.index, key)
            logEvent("manual_mode_write_attempted", "fan=\(fan.index) modeKey=\(key) mode=\(fan.mode) targetRPM=\(fan.targetRPM) value=1 strategy=direct")
            let direct = smc.writeKey(key, bytes: [1])
            if direct.success {
                logEvent("manual_mode_write_accepted", "fan=\(fan.index) modeKey=\(key) mode=\(fan.mode) targetRPM=\(fan.targetRPM) strategy=direct")
                try verifyAcceptedManualModeWrite(fan: fan, key: key, strategy: "direct")
                manualStrategy = "direct"
                lastTransitionDate = Date()
                logEvent("direct_mode_verified", "fan=\(fan.index) modeKey=\(key) mode=manual targetRPM=\(fan.targetRPM)")
                continue
            }
            logEvent("manual_mode_write_rejected", "fan=\(fan.index) modeKey=\(key) mode=\(fan.mode) targetRPM=\(fan.targetRPM) strategy=direct kernel=\(String(describing: direct.kernelReturn)) firmware=\(String(describing: direct.firmwareResult))")
            // The reverse-engineered Ftst path is only relevant when firmware
            // reports system-managed mode and rejects a direct mode write.
            guard fan.mode == "system", direct.kernelReturn == nil,
                  direct.firmwareResult == 0x82, ftstAvailability == "available" else {
                throw FanControllerError.unlockFailed("Direct \(key)=1 rejected (kernel=\(String(describing: direct.kernelReturn)), firmware=\(String(describing: direct.firmwareResult)))")
            }
            try enableOwnedFtst()
            logEvent("ftst_fallback_attempt", "fan=\(fan.index)")
            manualStrategy = "ftstFallback"
            let deadline = Date().addingTimeInterval(timing.manualVerificationTimeout)
            var fallbackWriteAttempted = false
            repeat {
                let mode = try readFanMode(fan.index)
                if mode == "manual" {
                    logEvent("manual_mode_delayed_verification", "fan=\(fan.index) modeKey=\(key) mode=manual targetRPM=\(fan.targetRPM) polls=fallback")
                    fallbackWriteAttempted = true
                    break
                }
                if mode == "auto" && !fallbackWriteAttempted {
                    attemptedManualModeKeys[fan.index] = key
                    try onManualModeWriteAttempt?(fan.index, key)
                    logEvent("manual_mode_write_attempted", "fan=\(fan.index) modeKey=\(key) mode=auto targetRPM=\(fan.targetRPM) value=1 strategy=ftstFallback")
                    let result = smc.writeKey(key, bytes: [1])
                    fallbackWriteAttempted = true
                    guard result.success else {
                        logEvent("manual_mode_write_rejected", "fan=\(fan.index) modeKey=\(key) mode=auto targetRPM=\(fan.targetRPM) strategy=ftstFallback kernel=\(String(describing: result.kernelReturn)) firmware=\(String(describing: result.firmwareResult))")
                        throw FanControllerError.unlockFailed("Ftst fallback \(key)=1 was rejected")
                    }
                    logEvent("manual_mode_write_accepted", "fan=\(fan.index) modeKey=\(key) mode=auto targetRPM=\(fan.targetRPM) strategy=ftstFallback")
                    try verifyAcceptedManualModeWrite(fan: fan, key: key, strategy: "ftstFallback")
                    break
                }
                Thread.sleep(forTimeInterval: timing.pollInterval)
            } while Date() < deadline
            guard fallbackWriteAttempted else { throw FanControllerError.unlockFailed("Ftst fallback did not reach a safe mode for fan \(fan.index)") }
            lastTransitionDate = Date()
        }
    }

    private func verifyAcceptedManualModeWrite(fan: FanReading, key: String, strategy: String) throws {
        let initialMode: String?
        do {
            initialMode = try readFanMode(fan.index)
            logEvent("manual_mode_initial_readback", "fan=\(fan.index) modeKey=\(key) mode=\(initialMode!) targetRPM=\(fan.targetRPM) strategy=\(strategy)")
        } catch {
            initialMode = nil
            logEvent("manual_mode_initial_readback", "fan=\(fan.index) modeKey=\(key) mode=unavailable targetRPM=\(fan.targetRPM) strategy=\(strategy) error=\(error)")
        }
        if initialMode == "manual" { return }

        let deadline = Date().addingTimeInterval(timing.manualVerificationTimeout)
        var polls = 0
        var validReadback = initialMode != nil
        var loggedReadFailure = false
        repeat {
            Thread.sleep(forTimeInterval: timing.pollInterval)
            polls += 1
            do {
                let mode = try readFanMode(fan.index)
                validReadback = true
                if mode == "manual" {
                    logEvent("manual_mode_delayed_verification", "fan=\(fan.index) modeKey=\(key) mode=manual targetRPM=\(fan.targetRPM) polls=\(polls) strategy=\(strategy)")
                    return
                }
            } catch {
                if !loggedReadFailure {
                    logEvent("manual_mode_readback_transient_failure", "fan=\(fan.index) modeKey=\(key) targetRPM=\(fan.targetRPM) firstPoll=\(polls) error=\(error)")
                    loggedReadFailure = true
                }
            }
        } while Date() < deadline

        if validReadback {
            logEvent("uncertain_hardware_state", "fan=\(fan.index) modeKey=\(key) mode=\(initialMode ?? "unavailable") targetRPM=\(fan.targetRPM) outcome=verification_timeout")
            throw FanControllerError.unlockFailed("\(key) write accepted; manual mode verification timed out after \(timing.manualVerificationTimeout)s")
        }
        logEvent("uncertain_hardware_state", "fan=\(fan.index) modeKey=\(key) mode=unavailable targetRPM=\(fan.targetRPM) outcome=readback_unavailable")
        throw FanControllerError.unlockFailed("\(key) write accepted; SMC mode readback remained unavailable or invalid")
    }

    private func enableOwnedFtst() throws {
        guard case .available = discoverFtst() else {
            throw FanControllerError.unlockFailed("Ftst unavailable or uncertain: \(ftstAvailability)")
        }
        let state = smc.readKey(Self.forceTestKey)
        guard state.success, state.size == 1, state.type == "ui8 ", state.bytes.count == 1 else {
            throw FanControllerError.unlockFailed("Ftst state unreadable or has unsupported type")
        }
        if state.bytes[0] == 1 {
            guard ownsFtst else { throw FanControllerError.unlockFailed("Ftst is active with unknown ownership") }
            return
        }
        guard state.bytes[0] == 0, recoveryURL != nil else {
            throw FanControllerError.unlockFailed("Ftst inactive state or durable recovery storage unavailable")
        }
        try persistOwnership(true)
        ownsFtst = true
        let result = smc.writeKey(Self.forceTestKey, bytes: [1])
        guard result.success else { throw FanControllerError.unlockFailed("Ftst=1 rejected (kernel=\(String(describing: result.kernelReturn)), firmware=\(String(describing: result.firmwareResult)))") }
        Thread.sleep(forTimeInterval: 0.5)
        let verify = smc.readKey(Self.forceTestKey)
        guard verify.success, verify.size == 1, verify.type == "ui8 ", verify.bytes == [1] else {
            throw FanControllerError.unlockFailed("Ftst=1 readback failed")
        }
        logEvent("ftst_enabled", "owner=CoolerMBP")
    }

    private func modeKey(for index: Int) throws -> String {
        if let cached = modeKeys[index] { return cached }

        // Lowercase is the known-working spelling on supported Apple Silicon.
        // Use uppercase only when lowercase is confirmed absent.
        let lowerKey = Self.key(Self.modeLowerTemplate, fan: index)
        switch smc.getKeyInfo(lowerKey) {
        case .available(let size, let type):
            guard size == 1, type == "ui8 " else {
                throw FanControllerError.readFailed("\(lowerKey) unsupported format size=\(size) type=\(type)")
            }
            modeKeys[index] = lowerKey
            return lowerKey
        case .failure(let failure):
            throw FanControllerError.readFailed("\(lowerKey) discovery failed: \(failure)")
        case .absent:
            break
        }

        let upperKey = Self.key(Self.modeUpperTemplate, fan: index)
        switch smc.getKeyInfo(upperKey) {
        case .available(let size, let type):
            guard size == 1, type == "ui8 " else {
                throw FanControllerError.readFailed("\(upperKey) unsupported format size=\(size) type=\(type)")
            }
            modeKeys[index] = upperKey
            return upperKey
        case .failure(let failure):
            throw FanControllerError.readFailed("\(upperKey) discovery failed: \(failure)")
        case .absent:
            throw FanControllerError.readFailed("F\(index)Md/F\(index)md (both aliases confirmed absent)")
        }
    }

    private func persistOwnership(_ owned: Bool) throws {
        guard let recoveryURL else { throw FanControllerError.unlockFailed("durable recovery path unavailable") }
        let directory = recoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(RecoveryMetadata(ownsFtst: owned))
        try data.write(to: recoveryURL, options: .atomic)
    }

    private static func readOwnership(from url: URL?) -> Bool {
        guard let url, let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(RecoveryMetadata.self, from: data) else { return false }
        return metadata.ownsFtst
    }

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let result = smc.readKey(Self.key(template, fan: fan))
        guard result.success, result.size == 4, result.type == "flt ", result.bytes.count == 4 else { return .nan }
        let value = Self.floatValue(result.bytes)
        return value.isFinite && value >= 0 && value < 100_000 ? value : .nan
    }

    private func logEvent(_ event: String, _ detail: String) {
        fputs("CoolerMBP: event=\(event) \(detail)\n", stderr)
    }

    private static func key(_ template: String, fan: Int) -> String {
        String(format: template, fan)
    }

    private static func floatValue(_ bytes: [UInt8]) -> Float {
        guard bytes.count >= 4 else { return 0 }
        var value: Float = 0
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: bytes.prefix(4))
        }
        return value
    }

    private static func floatBytes(_ value: Float) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func ioftValue(_ bytes: [UInt8]) -> Float {
        guard bytes.count >= 4 else { return 0 }
        var raw: UInt32 = 0
        withUnsafeMutableBytes(of: &raw) { destination in
            destination.copyBytes(from: bytes.prefix(4))
        }
        return Float(raw >> 16) + Float(raw & 0xffff) / 65536.0
    }
}

private struct RecoveryMetadata: Codable {
    let ownsFtst: Bool
}

private enum FtstCapability {
    case available
    case absent
    case unsupportedFormat(size: UInt32, type: String)
    case readError(SMCKeyInfoFailure)

    var diagnostic: String {
        switch self {
        case .available: return "available"
        case .absent: return "unavailable"
        case .unsupportedFormat(let size, let type): return "unsupported-format(size=\(size),type=\(type))"
        case .readError(let failure): return "read-error(\(failure))"
        }
    }
}
