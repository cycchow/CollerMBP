import XCTest
import CoolerShared
@testable import CoolerSMC

final class FanSafetyTests: XCTestCase {
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
        smc.failingWrites.insert("Ftst")
        let controller = FanController(smc: smc)
        XCTAssertThrowsError(try controller.resetAppleAutomatic())
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
}

private final class MockSMC: SMCTransport {
    var values: [String: [UInt8]]
    var failingWrites: Set<String> = []
    var targetReadDelay = 0
    private let hasFtst: Bool
    private var pendingTargets: [String: [UInt8]] = [:]

    init(fanCount: UInt8, hasFtst: Bool = false) {
        self.hasFtst = hasFtst
        values = ["FNum": [fanCount], "F0md": [0]]
        for index in 0..<Int(fanCount) where index < 10 {
            values["F\(index)Ac"] = Self.floatBytes(2000)
            values["F\(index)Tg"] = Self.floatBytes(2000)
            values["F\(index)Mn"] = Self.floatBytes(1200)
            values["F\(index)Mx"] = Self.floatBytes(6000)
            values["F\(index)md"] = [0]
        }
    }

    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32, type: String) {
        if let pending = pendingTargets[key] {
            if targetReadDelay > 0 {
                targetReadDelay -= 1
            } else {
                values[key] = pending
                pendingTargets[key] = nil
            }
        }
        guard let bytes = values[key] else { return (false, [], 0, "") }
        return (true, bytes, UInt32(bytes.count), "")
    }

    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        guard !failingWrites.contains(key) else { return false }
        if key.hasSuffix("Tg"), targetReadDelay > 0 {
            pendingTargets[key] = bytes
            return true
        }
        values[key] = bytes
        return true
    }

    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        key == "Ftst" && hasFtst ? (1, "ui8 ") : nil
    }

    private static func floatBytes(_ value: Float) -> [UInt8] {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}
