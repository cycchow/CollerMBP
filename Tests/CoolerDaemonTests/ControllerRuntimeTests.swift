import Foundation
import XCTest
import CoolerShared
@testable import CoolerSMC
@testable import CoolerDaemonCore

final class ControllerRuntimeTests: XCTestCase {
    func testManualModePersistsOnlyAfterHardwareVerification() throws {
        let (runtime, smc, configURL) = makeRuntime()
        let result = setMode(.maximum, on: runtime)
        XCTAssertNoThrow(try result.get())
        let status = status(of: runtime)
        XCTAssertEqual(status.mode, .maximum)
        XCTAssertEqual(status.persistedMode, .maximum)
        XCTAssertEqual(status.hardwareVerified, true)
        XCTAssertTrue(status.fans.allSatisfy { $0.mode == "manual" })
        XCTAssertEqual(try JSONDecoder().decode(DaemonConfig.self, from: Data(contentsOf: configURL)).mode, .maximum)
        XCTAssertGreaterThan(smc.writeCounts["F0md"] ?? 0, 0)
    }

    func testUnexpectedManualTargetChangePausesWithoutRecoveryWrites() throws {
        let (runtime, smc, _) = makeRuntime()
        XCTAssertNoThrow(try setMode(.maximum, on: runtime).get())
        smc.values["F0Tg"] = Self.floatBytes(2000)
        let writesBeforePoll = smc.totalWrites
        XCTAssertThrowsError(try runtime.pollForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesBeforePoll)
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
        XCTAssertThrowsError(try runtime.pollForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesBeforePoll)
    }

    func testStartupManualStateIsUnownedAndReadOnly() {
        let (runtime, smc, _) = makeRuntime()
        smc.values["F0md"] = [1]
        let writesBeforeStartup = smc.totalWrites
        XCTAssertThrowsError(try runtime.startupRecoveryForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesBeforeStartup)
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
    }

    func testStartupDoesNotResumePersistedManualModeWhenHardwareIsAutomatic() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(DaemonConfig(mode: .maximum)).write(to: configURL)
        let runtime = ControllerRuntime(fanController: FanController(smc: MockSMC(fanCount: 1)), configURL: configURL)

        XCTAssertNoThrow(try runtime.startupRecoveryForTesting().get())
        XCTAssertEqual(status(of: runtime).mode, .appleAuto)
        XCTAssertEqual(status(of: runtime).persistedMode, .appleAuto)
        XCTAssertEqual(status(of: runtime).hardwareVerified, true)
    }

    func testStartupRestoresManualFansMatchingOwnedRecoveryRecord() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let recoveryURL = configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        smc.values["F0Tg"] = Self.floatBytes(6000)
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .active, fans: [entry]), to: recoveryURL)
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)

        XCTAssertNoThrow(try runtime.startupRecoveryForTesting().get())
        XCTAssertEqual(status(of: runtime).fans.first?.mode, "auto")
        XCTAssertEqual(FanTransitionRecordFile.read(from: recoveryURL).isMissing, true)
    }

    func testStartupWithInvalidRecordLeavesManualFansUntouched() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let recoveryURL = configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: recoveryURL)
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)
        let writesBefore = smc.totalWrites

        XCTAssertThrowsError(try runtime.startupRecoveryForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesBefore)
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
    }

    func testStartupWithStaleRecordLeavesChangedManualTargetUntouched() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let recoveryURL = configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        smc.values["F0Tg"] = Self.floatBytes(4200)
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .active, fans: [entry]), to: recoveryURL)
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)
        let writesBefore = smc.totalWrites

        XCTAssertThrowsError(try runtime.startupRecoveryForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesBefore)
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
    }

    func testStartupReconcilesMatchingPartialTransition() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let recoveryURL = configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        let smc = MockSMC(fanCount: 2)
        smc.values["F0md"] = [1]
        smc.values["F0Tg"] = Self.floatBytes(6000)
        let entries = (0..<2).map { index in
            FanTransitionEntry(index: index, modeKey: "F\(index)md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        }
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: entries), to: recoveryURL)
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)

        XCTAssertNoThrow(try runtime.startupRecoveryForTesting().get())
        XCTAssertTrue(status(of: runtime).fans.allSatisfy { $0.mode == "auto" })
    }

    func testOrdinaryAutoRefusesUnknownManualOwnership() throws {
        let (runtime, smc, _) = makeRuntime()
        smc.values["F0md"] = [1]
        let writesBefore = smc.totalWrites
        let result = setMode(.appleAuto, on: runtime)

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(String(describing: error).contains("recover-unknown-fans"))
        }
        XCTAssertEqual(smc.totalWrites, writesBefore)
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
    }

    func testRecoveryMetadataWriteFailurePreventsManualSMCWrites() throws {
        let blocker = URL(fileURLWithPath: "/private/tmp/CoolerMBP-blocker-\(UUID().uuidString)")
        try Data("file".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let smc = MockSMC(fanCount: 1)
        let runtime = ControllerRuntime(
            fanController: FanController(smc: smc), configURL: configURL,
            fanRecoveryURL: blocker.appendingPathComponent("fan-recovery.json")
        )

        XCTAssertThrowsError(try setMode(.maximum, on: runtime).get())
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testPartialTransitionRecoveryFailureBlocksTimerUntilExplicitRecovery() throws {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let recoveryURL = configURL.deletingLastPathComponent().appendingPathComponent("fan-recovery.json")
        defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
        let smc = MockSMC(fanCount: 2)
        smc.failingWrites = { key, bytes in
            key == "F1md" && bytes == [1] || key == "F0md" && bytes == [0]
        }
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)

        XCTAssertThrowsError(try setMode(.maximum, on: runtime).get())
        XCTAssertEqual(status(of: runtime).recoveryRequired, true)
        XCTAssertEqual(status(of: runtime).hardwareVerified, false)
        if case .record = FanTransitionRecordFile.read(from: recoveryURL) {} else { XCTFail("uncertain rollback cleared ownership record") }
        let writesAfterFailure = smc.totalWrites
        XCTAssertThrowsError(try runtime.pollForTesting().get())
        XCTAssertEqual(smc.totalWrites, writesAfterFailure)

        smc.failingWrites = { _, _ in false }
        XCTAssertNoThrow(try setMode(.appleAuto, on: runtime).get())
        XCTAssertEqual(status(of: runtime).recoveryRequired, false)
        XCTAssertEqual(FanTransitionRecordFile.read(from: recoveryURL).isMissing, true)
        XCTAssertTrue(status(of: runtime).fans.allSatisfy { $0.mode == "auto" || $0.mode == "system" })
    }

    func testExplicitAutomaticRequestRecoversAndVerifiesHardware() throws {
        let (runtime, _, _) = makeRuntime()
        XCTAssertNoThrow(try setMode(.maximum, on: runtime).get())
        XCTAssertNoThrow(try setMode(.appleAuto, on: runtime).get())
        let status = status(of: runtime)
        XCTAssertEqual(status.mode, .appleAuto)
        XCTAssertEqual(status.persistedMode, .appleAuto)
        XCTAssertEqual(status.hardwareVerified, true)
        XCTAssertEqual(status.recoveryRequired, false)
        XCTAssertTrue(status.fans.allSatisfy { $0.mode == "auto" || $0.mode == "system" })
    }

    func testPersistenceFailureReportsVerifiedAutomaticFallback() throws {
        let blocker = URL(fileURLWithPath: "/private/tmp/CoolerMBP-blocker-\(UUID().uuidString)")
        try Data("file".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let configURL = blocker.appendingPathComponent("config.json")
        let fanRecoveryURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-fan-recovery-\(UUID().uuidString).json")
        let smc = MockSMC(fanCount: 1)
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL, fanRecoveryURL: fanRecoveryURL)

        XCTAssertThrowsError(try setMode(.maximum, on: runtime).get())
        let status = status(of: runtime)
        XCTAssertEqual(status.mode, .appleAuto)
        XCTAssertEqual(status.persistedMode, .appleAuto)
        XCTAssertEqual(status.hardwareVerified, true)
        XCTAssertTrue(status.lastError?.contains("Configuration persistence failed") == true)
        XCTAssertTrue(status.fans.allSatisfy { $0.mode == "auto" || $0.mode == "system" })
    }

    private func makeRuntime() -> (ControllerRuntime, MockSMC, URL) {
        let configURL = URL(fileURLWithPath: "/private/tmp/CoolerMBP-config-\(UUID().uuidString)/config.json")
        let smc = MockSMC(fanCount: 1)
        let runtime = ControllerRuntime(fanController: FanController(smc: smc), configURL: configURL)
        return (runtime, smc, configURL)
    }

    private func setMode(_ mode: CoolingMode, on runtime: ControllerRuntime) -> Result<Void, Error> {
        let done = expectation(description: "set mode \(mode)")
        var result: Result<Void, Error>!
        runtime.setMode(mode) { value in result = value; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func status(of runtime: ControllerRuntime) -> DaemonStatus {
        let done = expectation(description: "status")
        var value: DaemonStatus!
        runtime.getStatus { value = $0; done.fulfill() }
        wait(for: [done], timeout: 1)
        return value
    }

    private static func floatBytes(_ value: Float) -> [UInt8] {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

private extension FanTransitionRecordRead {
    var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

private final class MockSMC: SMCTransport {
    var values: [String: [UInt8]]
    var writeCounts: [String: Int] = [:]
    var failingWrites: (String, [UInt8]) -> Bool = { _, _ in false }
    var totalWrites: Int { writeCounts.values.reduce(0, +) }

    init(fanCount: UInt8) {
        values = ["FNum": [fanCount]]
        for index in 0..<Int(fanCount) {
            values["F\(index)md"] = [0]
            values["F\(index)Md"] = [0]
            values["F\(index)Ac"] = Self.floatBytes(2000)
            values["F\(index)Tg"] = Self.floatBytes(2000)
            values["F\(index)Mn"] = Self.floatBytes(1200)
            values["F\(index)Mx"] = Self.floatBytes(6000)
        }
    }

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32, type: String) {
        guard let bytes = values[key] else { return (false, [], 0, "") }
        return (true, bytes, UInt32(bytes.count), key == "FNum" || key.lowercased().contains("md") ? "ui8 " : "flt ")
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> SMCWriteResult {
        writeCounts[key, default: 0] += 1
        if failingWrites(key, bytes) { return SMCWriteResult(success: false, kernelReturn: -1, firmwareResult: nil) }
        values[key] = bytes
        return SMCWriteResult(success: true, kernelReturn: 0, firmwareResult: 0)
    }

    func getKeyInfo(_ key: String) -> SMCKeyInfoResult {
        if key == "Ftst" { return .absent }
        if key == "FNum" { return .available(size: 1, type: "ui8 ") }
        if key.range(of: #"F[0-9](Ac|Tg|Mn|Mx)"#, options: .regularExpression) != nil {
            return .available(size: 4, type: "flt ")
        }
        if key.range(of: #"F[0-9](md|Md)"#, options: .regularExpression) != nil, values[key] != nil {
            return .available(size: 1, type: "ui8 ")
        }
        return .absent
    }

    private static func floatBytes(_ value: Float) -> [UInt8] {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
