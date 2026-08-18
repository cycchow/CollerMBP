import Foundation
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
}

public final class FanController {
    private let smc: any SMCTransport
    private let modeKeyTemplate: String
    private let hasFtst: Bool

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

    public init() throws {
        guard let connection = SMCConnection() else { throw FanControllerError.connectionFailed }
        self.smc = connection

        let lowerKey = Self.key(Self.modeLowerTemplate, fan: 0)
        self.modeKeyTemplate = smc.readKey(lowerKey).success ? Self.modeLowerTemplate : Self.modeUpperTemplate
        self.hasFtst = (smc.getKeyInfo(Self.forceTestKey)?.size ?? 0) > 0
    }

    init(smc: any SMCTransport) {
        self.smc = smc

        let lowerKey = Self.key(Self.modeLowerTemplate, fan: 0)
        self.modeKeyTemplate = smc.readKey(lowerKey).success ? Self.modeLowerTemplate : Self.modeUpperTemplate
        self.hasFtst = (smc.getKeyInfo(Self.forceTestKey)?.size ?? 0) > 0
    }

    public var hardwareInfo: String {
        "Ftst=\(hasFtst ? "available" : "unavailable"), modeKey=\(modeKeyTemplate)"
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
            guard result.success, result.size == 4 else { continue }
            let value = Double(Self.floatValue(result.bytes))
            if value > 0, value < 150 { temperatures[key] = (value * 10).rounded() / 10 }
        }

        for key in Self.ioftTemperatureKeys {
            let result = smc.readKey(key)
            guard result.success, result.size == 8 else { continue }
            let value = Double(Self.ioftValue(result.bytes))
            if value > 0, value < 150 { temperatures[key] = (value * 10).rounded() / 10 }
        }

        return RawThermalStatus(fans: fans, temperatures: temperatures)
    }

    public func setCoolingLevel(_ level: Double) throws {
        let clamped = min(max(level, 0), 1)
        let count = try fanCount()
        let infos = try (0..<count).map(fanInfo)

        for fan in infos where fan.maxRPM <= fan.minRPM || fan.minRPM <= 0 {
            throw FanControllerError.invalidFanLimits(fan.index)
        }

        do {
            if infos.contains(where: { $0.mode != "manual" }) {
                try unlockFans(count: count)
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
                    if smc.writeKey(target.key, bytes: target.bytes) {
                        written = true
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                } while Date() < deadline
                guard written else {
                    let key = target.key
                    throw FanControllerError.writeFailed(key)
                }
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
                throw FanControllerError.writeFailed("\(failed.key) verification")
            }
        } catch let operationError {
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

    public func setMaximum() throws {
        try setCoolingLevel(1.0)
    }

    public func resetAppleAutomatic() throws {
        let count = try fanCount()
        var failures: [String] = []
        for index in 0..<count {
            let modeKey = Self.key(modeKeyTemplate, fan: index)
            if !smc.writeKey(modeKey, bytes: [0]) { failures.append(modeKey) }
        }
        if hasFtst {
            if !smc.writeKey(Self.forceTestKey, bytes: [0]) { failures.append(Self.forceTestKey) }
        }
        for index in 0..<count {
            let modeKey = Self.key(modeKeyTemplate, fan: index)
            let deadline = Date().addingTimeInterval(2)
            var restored = false
            repeat {
                let mode = try? fanInfo(index).mode
                if mode == "auto" || mode == "system" {
                    restored = true
                    break
                }
                _ = smc.writeKey(modeKey, bytes: [0])
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            if !restored { failures.append("fan \(index) mode verification") }
        }
        if !failures.isEmpty {
            throw FanControllerError.recoveryFailed(failures)
        }
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
        guard result.success, let first = result.bytes.first else {
            throw FanControllerError.readFailed(Self.fanCountKey)
        }
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
        let modeKey = Self.key(modeKeyTemplate, fan: index)
        let modeResult = smc.readKey(modeKey)
        let modeValue = modeResult.success ? (modeResult.bytes.first ?? 255) : 255
        let mode: String
        switch modeValue {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown(\(modeValue))"
        }

        return FanReading(
            index: index,
            actualRPM: Int(actual.rounded()),
            targetRPM: Int(target.rounded()),
            minRPM: Int(minimum.rounded()),
            maxRPM: Int(maximum.rounded()),
            mode: mode
        )
    }

    private func unlockFans(count: Int) throws {
        if hasFtst {
            guard smc.writeKey(Self.forceTestKey, bytes: [1]) else {
                throw FanControllerError.unlockFailed("Ftst=1 was rejected")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        for index in 0..<count {
            let modeKey = Self.key(modeKeyTemplate, fan: index)
            let deadline = Date().addingTimeInterval(8)
            var succeeded = false
            while Date() < deadline {
                if smc.writeKey(modeKey, bytes: [1]) {
                    succeeded = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard succeeded else {
                throw FanControllerError.unlockFailed("Timed out switching fan \(index) to manual mode")
            }
        }
    }

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let result = smc.readKey(Self.key(template, fan: fan))
        guard result.success, result.size == 4 else { return 0 }
        return Self.floatValue(result.bytes)
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
