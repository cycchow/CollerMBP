import Foundation
import CoolerShared

public enum FanTransitionPhase: String, Codable, Sendable {
    case transitioning
    case active
}

public struct FanTransitionEntry: Codable, Equatable, Sendable {
    public let index: Int
    public let modeKey: String
    public let previousMode: String
    public let previousTargetRPM: Int
    public let targetRPM: Int

    public init(index: Int, modeKey: String, previousMode: String, previousTargetRPM: Int, targetRPM: Int) {
        self.index = index
        self.modeKey = modeKey
        self.previousMode = previousMode
        self.previousTargetRPM = previousTargetRPM
        self.targetRPM = targetRPM
    }
}

public struct FanTransitionRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let phase: FanTransitionPhase
    public let fans: [FanTransitionEntry]
    public let attemptedFanIndexes: [Int]?

    public init(phase: FanTransitionPhase, fans: [FanTransitionEntry], attemptedFanIndexes: [Int]? = nil) {
        self.version = Self.currentVersion
        self.phase = phase
        self.fans = fans
        self.attemptedFanIndexes = attemptedFanIndexes
    }

    public func matches(_ readings: [FanReading]) -> Bool {
        guard version == Self.currentVersion, !fans.isEmpty, fans.count == readings.count else { return false }
        let readingsByIndex = Dictionary(uniqueKeysWithValues: readings.map { ($0.index, $0) })
        guard readingsByIndex.count == readings.count else { return false }
        let attempted = attemptedFanIndexes.map { Set($0) } ?? Set(fans.map(\.index))
        for entry in fans {
            guard let reading = readingsByIndex[entry.index], reading.modeKey == entry.modeKey else { return false }
            let atTarget = reading.mode == "manual" && abs(reading.targetRPM - entry.targetRPM) <= 100
            if phase == .active {
                guard atTarget else { return false }
                continue
            }
            let atPrevious = reading.mode == entry.previousMode && abs(reading.targetRPM - entry.previousTargetRPM) <= 100
            let manualOwnedByAttempt = reading.mode == "manual" && attempted.contains(entry.index) &&
                (atTarget || abs(reading.targetRPM - entry.previousTargetRPM) <= 100)
            let previouslyManual = entry.previousMode == "manual" && atPrevious
            guard atPrevious || manualOwnedByAttempt || previouslyManual else { return false }
        }
        return true
    }
}

public enum FanTransitionRecordRead {
    case missing
    case invalid
    case record(FanTransitionRecord)
}

public enum FanTransitionRecordFile {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/CoolerMBP/fan-recovery.json")

    public static func read(from url: URL) -> FanTransitionRecordRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(FanTransitionRecord.self, from: data),
              record.version == FanTransitionRecord.currentVersion,
              !record.fans.isEmpty,
              Set(record.fans.map(\.index)).count == record.fans.count else { return .invalid }
        return .record(record)
    }

    public static func write(_ record: FanTransitionRecord, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    public static func clear(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: url)
    }
}

public enum FanTransitionRecoveryError: Error, CustomStringConvertible {
    case unknownFanOwnership
    case unverifiedAutomaticState

    public var description: String {
        switch self {
        case .unknownFanOwnership:
            return "Manual fan ownership is unknown. Stop other fan-control tools; use recover-unknown-fans only if you intend to override their settings."
        case .unverifiedAutomaticState:
            return "Fan mode readback did not confirm Apple Automatic."
        }
    }
}

public enum FanTransitionRecovery {
    @discardableResult
    public static func restoreAppleAutomatic(
        using controller: FanController,
        recordURL: URL = FanTransitionRecordFile.defaultURL,
        allowUnknownFans: Bool = false,
        allowUnknownFtst: Bool = false
    ) throws -> RawThermalStatus {
        let current = try controller.status()
        var attemptedModeKeys: [Int: String] = [:]
        let recordRead = FanTransitionRecordFile.read(from: recordURL)
        if case .record(let record) = recordRead, record.phase == .transitioning {
            guard record.matches(current.fans) else {
                throw FanTransitionRecoveryError.unknownFanOwnership
            }
            let attempted = record.attemptedFanIndexes.map(Set.init) ?? Set(record.fans.map(\.index))
            attemptedModeKeys = Dictionary(uniqueKeysWithValues: record.fans.filter { attempted.contains($0.index) }.map { ($0.index, $0.modeKey) })
        }
        if current.fans.contains(where: { $0.mode == "manual" }), !allowUnknownFans {
            guard case .record(let record) = recordRead, record.matches(current.fans) else {
                throw FanTransitionRecoveryError.unknownFanOwnership
            }
        }
        do {
            try controller.resetAppleAutomatic(
                allowUnknownFtstRelease: allowUnknownFtst,
                attemptedFanModeKeys: attemptedModeKeys
            )
        } catch {
            fputs("CoolerMBP: event=ownership_record_retained reason=automatic_restore_unverified error=\(error)\n", stderr)
            throw error
        }
        let verified = try controller.status()
        guard verified.fans.allSatisfy({ $0.mode == "auto" || $0.mode == "system" }) else {
            throw FanTransitionRecoveryError.unverifiedAutomaticState
        }
        try FanTransitionRecordFile.clear(at: recordURL)
        fputs("CoolerMBP: event=ownership_record_cleared reason=stable_automatic_verified\n", stderr)
        return verified
    }
}
