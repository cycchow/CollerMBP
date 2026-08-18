import Foundation

public struct CoolingPolicy: Sendable {
    public static let startTemperature = 50.0
    public static let releaseTemperature = 48.0
    public static let releaseDelay: TimeInterval = 30.0
    public static let maximumTemperature = 80.0
    public static let hotspotEmergencyTemperature = 95.0

    // Cooling level is 0...1 across each fan's hardware min...max range.
    // Temperature is a smoothed representative CPU/GPU value, not a raw hotspot.
    // This curve is intentionally proactive for a warm 24-33 C room.
    private static let curve: [(temp: Double, level: Double)] = [
        (58.0, 0.25),
        (65.0, 0.40),
        (70.0, 0.60),
        (75.0, 0.80),
        (80.0, 1.00)
    ]

    public init() {}

    /// Returns nil when fan control should be handed back to macOS.
    public func targetLevel(
        temperature: Double,
        thermalState: String,
        currentlyManual: Bool,
        secondsBelowRelease: TimeInterval
    ) -> Double? {
        let state = thermalState.lowercased()
        if state == "serious" || state == "critical" {
            return 1.0
        }

        guard temperature.isFinite, temperature > 0 else {
            return nil
        }

        if temperature >= Self.maximumTemperature {
            return 1.0
        }

        if temperature < Self.releaseTemperature {
            if currentlyManual && secondsBelowRelease < Self.releaseDelay {
                return Self.curve[0].level
            }
            return nil
        }

        if temperature < Self.startTemperature {
            return currentlyManual ? Self.curve[0].level : nil
        }

        var level = interpolate(temperature)
        if state == "fair" {
            level = max(level, 0.72)
        }
        return min(max(level, 0.0), 1.0)
    }

    private func interpolate(_ temperature: Double) -> Double {
        if temperature <= Self.curve[0].temp { return Self.curve[0].level }
        if temperature >= Self.curve[Self.curve.count - 1].temp { return 1.0 }

        for i in 0..<(Self.curve.count - 1) {
            let a = Self.curve[i]
            let b = Self.curve[i + 1]
            if temperature >= a.temp && temperature <= b.temp {
                let position = (temperature - a.temp) / (b.temp - a.temp)
                return a.level + (b.level - a.level) * position
            }
        }
        return 1.0
    }
}
