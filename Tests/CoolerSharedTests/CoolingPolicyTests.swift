import XCTest
@testable import CoolerShared

final class CoolingPolicyTests: XCTestCase {
    let policy = CoolingPolicy()

    func testBelowStartHandsBackToApple() {
        XCTAssertNil(policy.targetLevel(temperature: 47, thermalState: "nominal", currentlyManual: false, secondsBelowRelease: 60))
    }

    func testSeventyDegreesUsesModerateStrongCooling() {
        let level = policy.targetLevel(temperature: 70, thermalState: "nominal", currentlyManual: false, secondsBelowRelease: 0)
        XCTAssertEqual(level ?? -1, 0.60, accuracy: 0.001)
    }

    func testEightyDegreesUsesMaximum() {
        XCTAssertEqual(policy.targetLevel(temperature: 80, thermalState: "nominal", currentlyManual: true, secondsBelowRelease: 0) ?? -1, 1.0, accuracy: 0.001)
    }

    func testSeriousThermalStateUsesMaximum() {
        XCTAssertEqual(policy.targetLevel(temperature: 62, thermalState: "serious", currentlyManual: true, secondsBelowRelease: 0) ?? -1, 1.0, accuracy: 0.001)
    }

    func testReleaseHysteresis() {
        XCTAssertNotNil(policy.targetLevel(temperature: 47, thermalState: "nominal", currentlyManual: true, secondsBelowRelease: 10))
        XCTAssertNil(policy.targetLevel(temperature: 47, thermalState: "nominal", currentlyManual: true, secondsBelowRelease: 31))
    }

    func testDefaultConfigurationUsesAppleControl() {
        XCTAssertEqual(DaemonConfig().mode, .appleAuto)
    }

    func testRepresentativeTemperatureUsesWarmerGroupAverage() {
        let temperatures = ["Tp01": 60.0, "TCMb": 70.0, "Tg05": 50.0]
        XCTAssertEqual(TemperatureControl.representative(from: temperatures) ?? -1, 65.0, accuracy: 0.001)
    }

    func testTemperatureMovingAverageUsesBoundedWindow() {
        var average = TemperatureMovingAverage(sampleCount: 3)
        _ = average.add(50)
        _ = average.add(60)
        XCTAssertEqual(average.add(70), 60, accuracy: 0.001)
        XCTAssertEqual(average.add(80), 70, accuracy: 0.001)
    }
}
