import XCTest
import CoolerShared
@testable import CoolerSMC

final class FanSafetyTests: XCTestCase {
    private func transitionTestController(
        smc: MockSMC,
        recoveryURL: URL? = nil,
        writeEnabled: Bool = true,
        modelIdentifier: String? = "TestModel"
    ) -> FanController {
        FanController(
            smc: smc, recoveryURL: recoveryURL, writeEnabled: writeEnabled,
            modelIdentifier: modelIdentifier, manualControlForTesting: true
        )
    }

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
        let controller = transitionTestController(smc: smc)
        XCTAssertThrowsError(try controller.status())
    }

    func testResetFailureIsReported() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        smc.failingWrites.insert("Ftst")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("{\"ownsFtst\":true}".utf8).write(to: url)
        let controller = transitionTestController(smc: smc, recoveryURL: url)
        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["Ftst"], [1])
    }

    func testTargetFailureRestoresAutomaticMode() {
        let smc = MockSMC(fanCount: 1)
        smc.failingWrites.insert("F0Tg")
        let controller = transitionTestController(smc: smc)

        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testDelayedTargetReadbackIsAccepted() {
        let smc = MockSMC(fanCount: 1)
        smc.targetReadDelay = 3
        let controller = transitionTestController(smc: smc)

        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
    }

    func testDirectManualControlDoesNotTouchFtst() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        let controller = transitionTestController(smc: smc)
        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testConfirmedFtstAbsencePreservesDirectManualControl() {
        let smc = MockSMC(fanCount: 1)
        XCTAssertNoThrow(try transitionTestController(smc: smc).setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testMac149ManualControlIsDisabledWithoutHardwareSequenceEvidence() {
        let smc = MockSMC(fanCount: 1)
        let controller = transitionTestController(smc: smc, modelIdentifier: "Mac14,9")

        XCTAssertThrowsError(try controller.setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("manual control is disabled on Mac14,9"))
        }
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testUnknownHardwareModelBlocksManualWrites() {
        let smc = MockSMC(fanCount: 1)
        let controller = FanController(smc: smc, modelIdentifier: nil)

        XCTAssertThrowsError(try controller.setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("model identifier is unavailable"))
        }
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testOtherUnvalidatedHardwareModelBlocksManualWrites() {
        let smc = MockSMC(fanCount: 1)
        let controller = FanController(smc: smc, modelIdentifier: "Mac15,3")

        XCTAssertThrowsError(try controller.setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("unvalidated hardware model Mac15,3"))
        }
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testPositivePreviousTargetBelowMinimumBlocksManualWrites() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0Tg"] = MockSMC.floatBytes(500)

        XCTAssertThrowsError(try transitionTestController(smc: smc).setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("targetRPM=500"))
            XCTAssertTrue(String(describing: error).contains("minRPM=1200"))
        }
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testInvalidFanRangeBlocksManualWrites() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0Mn"] = MockSMC.floatBytes(0)

        XCTAssertThrowsError(try transitionTestController(smc: smc).setMaximum())
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testZeroPreviousTargetBlocksManualActivation() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0Tg"] = MockSMC.floatBytes(0)

        XCTAssertThrowsError(try transitionTestController(smc: smc).setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("targetRPM=0"))
        }
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["F0Tg"])
    }

    func testImmediateManualModeReadbackIsVerified() throws {
        let smc = MockSMC(fanCount: 1)

        try transitionTestController(smc: smc).setMaximum()

        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertGreaterThan(try transitionTestController(smc: smc).status().fans[0].targetRPM, 0)
        XCTAssertEqual(smc.writeCounts["F0md"], 1)
    }

    func testDelayedManualModeReadbackIsVerifiedWithoutRepeatingWrite() throws {
        let smc = MockSMC(fanCount: 1)
        smc.manualModeReadDelays["F0md"] = 3

        try transitionTestController(smc: smc).setMaximum()

        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertEqual(smc.writeCounts["F0md"], 1)
    }

    func testTransientModeReadbackFailureCanRecoverWithinBoundedVerification() throws {
        let smc = MockSMC(fanCount: 1)
        smc.modeReadFailuresAfterManualWrite["F0md"] = 1

        try transitionTestController(smc: smc).setMaximum()

        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertEqual(smc.writeCounts["F0md"], 1)
    }

    func testAcceptedButUnverifiedManualWriteIsRolledBackAfterDelayedActivation() {
        let smc = MockSMC(fanCount: 1)
        smc.manualModeReadDelays["F0md"] = 30

        XCTAssertThrowsError(try transitionTestController(smc: smc).setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("verification timed out"))
        }

        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertGreaterThanOrEqual(smc.writeCounts["F0md"] ?? 0, 3, "rollback must re-write Auto after delayed Manual activation")
    }

    func testFailedTransitionWithVerifiedRollbackReturnsAllFansToAutomatic() {
        let smc = MockSMC(fanCount: 2)
        smc.failingWrites.insert("F1Tg")

        XCTAssertThrowsError(try transitionTestController(smc: smc).setCoolingLevel(0.5))

        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["F1md"], [0])
    }

    func testRollbackUncertaintyIsReportedWhenAutomaticWriteCannotTakeEffect() {
        let smc = MockSMC(fanCount: 1)
        smc.ignoredAutoWrites.insert("F0md")
        smc.failingWrites.insert("F0Tg")

        XCTAssertThrowsError(try transitionTestController(smc: smc).setMaximum()) { error in
            XCTAssertTrue(String(describing: error).contains("recovery"))
        }
        XCTAssertEqual(smc.values["F0md"], [1])
    }

    func testRecordedPendingTransitionCannotClearRecoveryRecordOnImmediateAutoReadback() throws {
        let smc = MockSMC(fanCount: 1)
        smc.pendingManualModes["F0md"] = 8
        smc.ignoredWrites.insert("F0md")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: [entry], attemptedFanIndexes: [0]), to: url)

        XCTAssertThrowsError(try FanTransitionRecovery.restoreAppleAutomatic(using: transitionTestController(smc: smc), recordURL: url))

        if case .record = FanTransitionRecordFile.read(from: url) {} else { XCTFail("uncertain rollback cleared transition record") }
        XCTAssertEqual(smc.values["F0md"], [1])
    }

    func testRecoveryClearsTransitionRecordOnlyAfterStableAutomaticReadback() throws {
        let smc = MockSMC(fanCount: 1)
        smc.pendingManualModes["F0md"] = 5
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: [entry], attemptedFanIndexes: [0]), to: url)

        let restored = try FanTransitionRecovery.restoreAppleAutomatic(using: transitionTestController(smc: smc), recordURL: url)

        XCTAssertEqual(restored.fans.first?.mode, "auto")
        XCTAssertEqual(FanTransitionRecordFile.read(from: url).isMissing, true)
        XCTAssertGreaterThanOrEqual(smc.writeCounts["F0md"] ?? 0, 2)
    }

    func testRecordedPartialTransitionRestoresOnlyAttemptedFanAndPreservesOwnership() throws {
        let smc = MockSMC(fanCount: 2)
        smc.values["F0md"] = [1]
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = (0..<2).map { index in
            FanTransitionEntry(index: index, modeKey: "F\(index)md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        }
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: entries, attemptedFanIndexes: [0]), to: url)

        let restored = try FanTransitionRecovery.restoreAppleAutomatic(using: transitionTestController(smc: smc), recordURL: url)

        XCTAssertTrue(restored.fans.allSatisfy { $0.mode == "auto" })
        XCTAssertGreaterThan(smc.writeCounts["F0md"] ?? 0, 0)
        XCTAssertNil(smc.writeCounts["F1md"])
        XCTAssertEqual(FanTransitionRecordFile.read(from: url).isMissing, true)
    }

    func testMac149RestrictionDoesNotBlockRecordedPartialAutomaticRecovery() throws {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: [entry], attemptedFanIndexes: [0]), to: url)

        let restored = try FanTransitionRecovery.restoreAppleAutomatic(
            using: FanController(smc: smc, modelIdentifier: "Mac14,9"), recordURL: url
        )

        XCTAssertEqual(restored.fans.first?.mode, "auto")
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(FanTransitionRecordFile.read(from: url).isMissing, true)
    }

    func testEmptyTransitionAttemptRecordDoesNotClaimMatchingUnknownManualState() throws {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = FanTransitionEntry(index: 0, modeKey: "F0md", previousMode: "auto", previousTargetRPM: 2000, targetRPM: 6000)
        try FanTransitionRecordFile.write(FanTransitionRecord(phase: .transitioning, fans: [entry], attemptedFanIndexes: []), to: url)

        XCTAssertThrowsError(try FanTransitionRecovery.restoreAppleAutomatic(using: transitionTestController(smc: smc), recordURL: url))

        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        if case .record = FanTransitionRecordFile.read(from: url) {} else { XCTFail("unknown manual state destroyed transition record") }
    }

    func testFtstFirmwareDiscoveryFailureBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .failure(SMCKeyInfoFailure(kernelReturn: nil, firmwareResult: 0x82))

        XCTAssertThrowsError(try transitionTestController(smc: smc).resetAppleAutomatic())
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(transitionTestController(smc: smc).hardwareInfo.contains("firmware=Optional(130)"))
    }

    func testOrdinaryRecoveryRefusesUnknownManualFanOwnership() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]

        XCTAssertThrowsError(try FanTransitionRecovery.restoreAppleAutomatic(using: transitionTestController(smc: smc)))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
    }

    func testExplicitFanRecoveryOverridesUnknownManualOwnership() throws {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [1]

        let restored = try FanTransitionRecovery.restoreAppleAutomatic(
            using: transitionTestController(smc: smc), allowUnknownFans: true
        )
        XCTAssertEqual(restored.fans.first?.mode, "auto")
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testExplicitFanRecoveryStillRequiresKnownFtstOwnership() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["Ftst"] = [1]

        XCTAssertThrowsError(try FanTransitionRecovery.restoreAppleAutomatic(
            using: transitionTestController(smc: smc), allowUnknownFans: true
        ))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testUnsupportedFtstFormatBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .available(size: 2, type: "ui8 ")

        XCTAssertThrowsError(try transitionTestController(smc: smc).resetAppleAutomatic())
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(transitionTestController(smc: smc).hardwareInfo.contains("unsupported-format"))
    }

    func testFtstUnknownOwnershipIsNotCleared() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let controller = transitionTestController(smc: smc)
        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["Ftst"], [1])
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testUnknownFtstPreflightPreventsAllFanModeWrites() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["Ftst"] = [1]
        let controller = transitionTestController(smc: smc)

        XCTAssertThrowsError(try controller.resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }

    func testUnsupportedFtstValueBlocksAllFanModeWrites() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.values["Ftst"] = [2]

        XCTAssertThrowsError(try transitionTestController(smc: smc).resetAppleAutomatic())
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

        XCTAssertThrowsError(try transitionTestController(smc: smc, recoveryURL: url).resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["F1md"], [1])
        XCTAssertEqual(smc.values["Ftst"], [1])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"ownsFtst\":true}".utf8))
    }

    func testExplicitUnknownFtstRecoveryReleasesAndVerifies() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let controller = transitionTestController(smc: smc)
        XCTAssertNoThrow(try controller.resetAppleAutomatic(allowUnknownFtstRelease: true))
        XCTAssertEqual(smc.values["Ftst"], [0])
    }

    func testAlreadyAutomaticFansStillReleaseOwnedFtst() throws {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["Ftst"] = [1]
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"ownsFtst\":true}".utf8).write(to: url)
        let controller = transitionTestController(smc: smc, recoveryURL: url)
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
        let controller = transitionTestController(smc: smc, recoveryURL: url)

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
        let controller = transitionTestController(smc: smc, recoveryURL: URL(fileURLWithPath: "/private/tmp/unused-recovery.json"))

        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstUnavailableNeverWritesFtst() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        let controller = transitionTestController(smc: smc)
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstReadFailureDoesNotWriteIt() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        smc.unreadableKeys.insert("Ftst")
        let controller = transitionTestController(smc: smc, recoveryURL: URL(fileURLWithPath: "/private/tmp/unused-recovery.json"))
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.writeCounts["Ftst"], nil)
    }

    func testFtstKeyInfoFailureBlocksRecoveryBeforeWrites() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [1]
        smc.keyInfoResults["Ftst"] = .failure(SMCKeyInfoFailure(kernelReturn: -1, firmwareResult: nil))

        XCTAssertThrowsError(try transitionTestController(smc: smc).resetAppleAutomatic())
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertNil(smc.writeCounts["F0md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
        XCTAssertTrue(transitionTestController(smc: smc).hardwareInfo.contains("Ftst=read-error"))
    }

    func testFtstWriteFailureIsReported() {
        let smc = MockSMC(fanCount: 1, hasFtst: true)
        smc.values["F0md"] = [3]
        smc.rejectedWrites.insert("F0md")
        smc.failingWrites.insert("Ftst")
        let url = URL(fileURLWithPath: "/private/tmp/CoolerMBP-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = transitionTestController(smc: smc, recoveryURL: url)
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
        XCTAssertThrowsError(try transitionTestController(smc: smc, recoveryURL: url).setCoolingLevel(0.5))
    }

    func testRepeatedManualAndAutomaticRequestsAreIdempotent() throws {
        let smc = MockSMC(fanCount: 1)
        let controller = transitionTestController(smc: smc)
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
        let controller = transitionTestController(smc: smc)
        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
        XCTAssertEqual(smc.values["F1md"], [0])
    }

    func testTargetWriteAcceptedButReadbackMismatchFails() {
        let smc = MockSMC(fanCount: 1)
        smc.ignoredWrites.insert("F0Tg")
        XCTAssertThrowsError(try transitionTestController(smc: smc).setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [0])
    }

    func testUnsupportedModeKeyTypeIsRejected() {
        let smc = MockSMC(fanCount: 1)
        smc.invalidKeyTypes["F0md"] = "flt "
        XCTAssertThrowsError(try transitionTestController(smc: smc).status())
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
        let status = try transitionTestController(smc: smc).status()
        XCTAssertEqual(status.fans.map(\.modeKey), ["F0md", "F1Md"])
    }

    func testBothModeAliasesPreferAndKeepLowercaseKey() throws {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0Md"] = [3]
        let controller = transitionTestController(smc: smc)

        XCTAssertEqual(try controller.status().fans.first?.modeKey, "F0md")
        XCTAssertNoThrow(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0md"], [1])
        XCTAssertEqual(smc.values["F0Md"], [3])
        XCTAssertEqual(smc.writeCounts["F0Md"], nil)
    }

    func testRejectedPreferredModeAliasDoesNotProbeUppercase() {
        let smc = MockSMC(fanCount: 1)
        smc.values["F0Md"] = [3]
        smc.rejectedWrites.insert("F0md")
        let controller = transitionTestController(smc: smc)

        XCTAssertThrowsError(try controller.setCoolingLevel(0.5))
        XCTAssertEqual(smc.values["F0Md"], [3])
        XCTAssertNil(smc.writeCounts["F0Md"])
        XCTAssertNil(smc.writeCounts["Ftst"])
    }
}

private final class MockSMC: SMCTransport {
    var values: [String: [UInt8]]
    var failingWrites: Set<String> = []
    var rejectedWrites: Set<String> = []
    var writeCounts: [String: Int] = [:]
    var targetReadDelay = 0
    var manualModeReadDelays: [String: Int] = [:]
    var modeReadFailuresRemaining: [String: Int] = [:]
    var modeReadFailuresAfterManualWrite: [String: Int] = [:]
    var unreadableKeys: Set<String> = []
    var ignoredWrites: Set<String> = []
    var ignoredAutoWrites: Set<String> = []
    var invalidKeyTypes: [String: String] = [:]
    var keyInfoResults: [String: SMCKeyInfoResult] = [:]
    private let hasFtst: Bool
    private var pendingTargets: [String: [UInt8]] = [:]
    var pendingManualModes: [String: Int] = [:]

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
        if let remaining = modeReadFailuresRemaining[key], remaining > 0 {
            modeReadFailuresRemaining[key] = remaining - 1
            return (false, [], 0, "")
        }
        if let remaining = pendingManualModes[key] {
            if remaining <= 1 {
                values[key] = [1]
                pendingManualModes[key] = nil
            } else {
                pendingManualModes[key] = remaining - 1
            }
        }
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
        if key.lowercased().contains("md"), bytes == [1] {
            let delay = manualModeReadDelays[key] ?? 0
            modeReadFailuresRemaining[key] = modeReadFailuresAfterManualWrite[key]
            if delay > 0 { pendingManualModes[key] = delay }
            else if !ignoredWrites.contains(key) { values[key] = [1] }
        } else if key.lowercased().contains("md"), bytes == [0] {
            let wasManual = values[key] == [1]
            if !ignoredWrites.contains(key) && !ignoredAutoWrites.contains(key) { values[key] = [0] }
            if wasManual { pendingManualModes[key] = nil }
        } else if !ignoredWrites.contains(key) {
            values[key] = bytes
        }
        if key == "Ftst", bytes == [1] {
            for index in 0..<10 where values["F\(index)md"] == [3] { values["F\(index)md"] = [0] }
        }
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

    fileprivate static func floatBytes(_ value: Float) -> [UInt8] {
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
