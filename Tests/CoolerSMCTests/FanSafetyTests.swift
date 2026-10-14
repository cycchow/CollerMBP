import XCTest
import CoolerShared
@testable import CoolerSMC

final class FanSafetyTests: XCTestCase {
    func testKeyInfoResponseClassifiesConfirmedAbsence() {
        XCTAssertEqual(
            SMCKeyInfoResponse.classify(kernelReturn: 0, firmwareResult: 0x84, size: 0, type: "????"),
            .absent
        )
    }

    func testKeyInfoResponsePreservesKernelAndFirmwareFailures() {
        XCTAssertEqual(
            SMCKeyInfoResponse.classify(kernelReturn: -1, firmwareResult: 0, size: 0, type: "????"),
            .failure(SMCKeyInfoFailure(kernelReturn: -1, firmwareResult: nil))
        )
        XCTAssertEqual(
            SMCKeyInfoResponse.classify(kernelReturn: 0, firmwareResult: 0x82, size: 0, type: "????"),
            .failure(SMCKeyInfoFailure(kernelReturn: nil, firmwareResult: 0x82))
        )
    }

    func testHealthyFanResponsePasses() throws {
        let fan = FanReading(index: 0, actualRPM: 3500, targetRPM: 3700, minRPM: 1200, maxRPM: 6000, mode: "manual")
        XCTAssertNoThrow(try FanController.verifyFanResponse([fan]))
    }

    func testStalledFanResponseFails() {
        let fan = FanReading(index: 0, actualRPM: 1200, targetRPM: 5000, minRPM: 1200, maxRPM: 6000, mode: "manual")
        XCTAssertThrowsError(try FanController.verifyFanResponse([fan]))
    }

    func testAutomaticFanIsNotTreatedAsStalled() throws {
        let fan = FanReading(index: 0, actualRPM: 0, targetRPM: 5000, minRPM: 1200, maxRPM: 6000, mode: "auto")
        XCTAssertNoThrow(try FanController.verifyFanResponse([fan]))
    }

    func testInvalidFanCountIsRejected() {
        let smc = MockSMC(fanCount: 11)
        let controller = FanController(smc: smc)
        XCTAssertThrowsError(try controller.status())
    }

    func testResetFailureIsReported() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        smc.failingWrites.insert("Ftst")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("{\"ownsFtst\":true}".utf8).write(to: url)
        let controller = FanController(smc: smc, recoveryURL: url)
        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["Ftst"], [1])
    }

    func testTargetFailureRestoresAutomaticMode() {
        let smc = MockSMC(fanCount: 1)
        smc.failingWrites.insert("F0Tg")
        let controller = FanController(smc: smc)

        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testDelayedTargetReadbackIsAccepted() {
        let smc = MockSMC(fanCount: 1)
        smc.targetReadDelay = 3
        let controller = FanController(smc: smc)

        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
    }

    func testDirectManualControlDoesNotTouchFtst() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        let controller = FanController(smc: smc)
        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testConfirmedFtstAbsencePreservesDirectManualControl() {
        let smc = MockSMC(fanCount: 1)
        XCTAssertNoThrow(try FanController(smc: smc).setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testFtstFirmwareDiscoveryFailureBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .failure(SMCKeyInfoFailure(kernelReturn: nil, firmwareResult: 0x82))

        XCTAssertThrowsError(try FanController(smc: smc).resetAppleAutomatic())
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(FanController(smc: smc).hardwareInfo.contains("firmware=Optional(130)"))
    }

    func testUnsupportedFtstFormatBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .available(size: 2, type: "ui8 ")

        XCTAssertThrowsError(try FanController(smc: smc).resetAppleAutomatic())
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(FanController(smc: smc).hardwareInfo.contains("unsupported-format"))
    }

    func testFtstUnknownOwnershipIsNotCleared() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let controller = FanController(smc: smc)
        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["Ftst"], [1])
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testUnknownFtstPreflightPreventsAllFanModeWrites() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["Ftst"] = [1]
        let controller = FanController(smc: smc)

        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testUnsupportedFtstValueBlocksAllFanModeWrites() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["Ftst"] = [2]

        XCTAssertThrowsError(try FanController(smc: smc).resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testPartialFanRestoreKeepsOwnedFtstActive() throws {
        let smc = MockSMC(fanCount: 2, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["F1md"] = [1]
        smc.values["Ftst"] = [1]
        smc.failingWrites.insert("F1md")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"ownsFtst\":true}".utf8).write(to: url)

        XCTAssertThrowsError(try FanController(smc: smc, recoveryURL: url).resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["F1md"], [1])
        XCTAssertEqual(smc.values["Ftst"], [1])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"ownsFtst\":true}".utf8))
    }

    func testExplicitUnknownFtstRecoveryReleasesAndVerifies() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let controller = FanController(smc: smc)
        XCTAssertNoThrow(try controller.resetAppleAutomatic(allowUnknownFtstRelease: true))
        XCTAssertEqual(smc.values["Ftst"], [0])
    }

    func testAlreadyAutomaticFansStillReleaseOwnedFtst() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"ownsFtst\":true}".utf8).write(to: url)
        let controller = FanController(smc: smc, recoveryURL: url)
        XCTAssertNoThrow(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["Ftst"], [0])
    }

    func testSupportedFtstFallbackAndOwnedRelease() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = FanController(smc: smc, recoveryURL: url)

        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertEqual(smc.values["Ftst"], [1])
        XCTAssertNoThrow(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["Ftst"], [0])
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testKernelWriteFailureDoesNotAuthorizeFtstFallback() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.failingWrites.insert("F0md")
        let controller = FanController(smc: smc, recoveryURL: URL(fileURLWithPath: "/private/tmp/unused-recovery.json"))

        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstUnavailableNeverWritesFtst() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        let controller = FanController(smc: smc)
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstReadFailureDoesNotWriteIt() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        smc.unreadableKeys.insert("Ftst")
        let controller = FanController(smc: smc, recoveryURL: URL(fileURLWithPath: "/private/tmp/unused-recovery.json"))
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstKeyInfoFailureBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .failure(SMCKeyInfoFailure(kernelReturn: -1, firmwareResult: nil))

        XCTAssertThrowsError(try FanController(smc: smc).resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(FanController(smc: smc).hardwareInfo.contains("Ftst=read-error"))
    }

    func testFtstWriteFailureIsReported() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        smc.failingWrites.insert("Ftst")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = FanController(smc: smc, recoveryURL: url)
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["Ftst"], [0])
    }

    func testFtstWriteReadbackMismatchIsReported() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        smc.ignoredWrites.insert("Ftst")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FanController(smc: smc, recoveryURL: url).setCoolingLevel(0.5))
    }

    func testRepeatedManualAndAutomaticRequestsAreIdempotent() throws {
        let smc = MockSMC(fanCount: 1)
        let controller = FanController(smc: smc)
        try controller.setCoolingLevel(0.5)
        let manualWrites = smc.writeCounts["F0md"]
        try controller.setCoolingLevel(0.6)
        XCTAssertEqual(smc.writeCounts["F0md"], manualWrites)
        try controller.resetAppleAutomatic()
        let automaticWrites = smc.writeCounts["F0md"]
        try controller.resetAppleAutomatic()
        XCTAssertEqual(smc.writeCounts["F0md"], automaticWrites)
    }

    func testPartialManualTransitionRestoresPreviouslyChangedFan() {
        let smc = MockSMC(fanCount: 2)
        smc.failingWrites.insert("F1md")
        let controller = FanController(smc: smc)
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["F1md"], [0])
    }

    func testTargetWriteAcceptedButReadbackMismatchFails() {
        let smc = MockSMC(fanCount: 1)
        smc.ignoredWrites.insert("F0Tg")
        XCTAssertThrowsError(try FanController(smc: smc).setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testUnsupportedModeKeyTypeIsRejected() {
        let smc = MockSMC(fanCount: 1)
        smc.invalidKeyTypes["F0md"] = "flt "
        XCTAssertThrowsError(try FanController(smc: smc).status())
    }

    func testSMCWriterLockPreventsSecondWriter() throws {
        let path = "/private/tmp/CoolerMBP-lock-\(UUID().uuidString)"
        var first: SMCWriterLock? = try SMCWriterLock(path: path)
        XCTAssertThrowsError(try SMCWriterLock(path: path))
        withExtendedLifetime(first) {}
        first = nil
        let afterRelease = try SMCWriterLock(path: path)
        withExtendedLifetime(afterRelease) {}
        try? FileManager.default.removeItem(atPath: path)
    }

    func testPerFanModeKeyIsDiscoveredIndividually() throws {
        let smc = MockSMC(fanCount: 2)
        smc.values.removeValue(forKey: "F1md")
        smc.values["F1Md"] = [0]
        let status = try FanController(smc: smc).status()
        XCTAssertEqual(status.fans.map(\.modeKey), ["F0md", "F1Md"])
    }
}

private final class MockSMC: SMCTransport {
    var values: [String: [UInt8]]
    var failingWrites: Set<String> = []
    var rejectedWrites: Set<String> = []
    var writeCounts: [String: Int] = [:]
    var targetReadDelay = 0
    var unreadableKeys: Set<String> = []
    var ignoredWrites: Set<String> = []
    var invalidKeyTypes: [String: String] = [:]
    var keyInfoResults: [String: SMCKeyInfoResult] = [:]
    private let hasFtst: Bool
    private var pendingTargets: [String: [UInt8]] = [:]

    init(fanCount: UInt8, hasFtst: Bool = false) {
        self.hasFtst = hasFtst
        values = ["FNum": [fanCount], "F0md": [0]]
        if hasFtst { values["Ftst"] = [0] }
        for index in 0..<Int(fanCount) where index < 10 {
            values["F\(index)Ac"] = Self.floatBytes(2000)
            values["F\(index)Tg"] = Self.floatBytes(2000)
            values["F\(index)Mn"] = Self.floatBytes(1200)
            values["F\(index)Mx"] = Self.floatBytes(6000)
            values["F\(index)md"] = [0]
        }
    }

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32, type: String) {
        if unreadableKeys.contains(key) { return (false, [], 0, "") }
        if let pending = pendingTargets[key] {
            if targetReadDelay > 0 {
                targetReadDelay -= 1
            } else {
                values[key] = pending
                pendingTargets[key] = nil
            }
        }
        guard let bytes = values[key] else { return (false, [], 0, "") }
        return (true, bytes, UInt32(bytes.count), invalidKeyTypes[key] ?? (key == "FNum" || key.lowercased().contains("md") || key == "Ftst" ? "ui8 " : "flt "))
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> SMCWriteResult {
        writeCounts[key, default: 0] += 1
        guard !failingWrites.contains(key) else { return SMCWriteResult(success: false, kernelReturn: -1, firmwareResult: nil) }
        if rejectedWrites.contains(key), bytes == [1], !(key.lowercased().contains("md") && values["Ftst"] == [1]) {
            return SMCWriteResult(success: false, kernelReturn: nil, firmwareResult: 0x82)
        }
        if key.hasSuffix("Tg"), targetReadDelay > 0 {
            pendingTargets[key] = bytes
            return SMCWriteResult(success: true, kernelReturn: nil, firmwareResult: 0)
        }
        if !ignoredWrites.contains(key) { values[key] = bytes }
        if key == "Ftst", bytes == [1] {
            for index in 0..<10 where values["F\(index)md"] == [3] { values["F\(index)md"] = [0] }
        }
        if key.contains("md"), bytes == [1] { values[key] = [1] }
        return SMCWriteResult(success: true, kernelReturn: nil, firmwareResult: 0)
    }

    func getKeyInfo(_ key: String) -> SMCKeyInfoResult {
        if let result = keyInfoResults[key] { return result }
        if key == "Ftst" { return hasFtst ? .available(size: 1, type: "ui8 ") : .absent }
        if key == "FNum" { return .available(size: 1, type: "ui8 ") }
        if key.range(of: #"F[0-9](Ac|Tg|Mn|Mx)"#, options: .regularExpression) != nil { return .available(size: 4, type: "flt ") }
        if key.range(of: #"F[0-9](md|Md)"#, options: .regularExpression) != nil,
           values[key] != nil { return .available(size: 1, type: invalidKeyTypes[key] ?? "ui8 ") }
        return .absent
    }

    private static func floatBytes(_ value: Float) -> [UInt8] {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
