import Foundation

public enum TemperatureControl {
    public static func representative(from temperatures: [String: Double]) -> Double? {
        let cpu = matching(temperatures, prefixes: ["TC", "Tp"])
        let gpu = matching(temperatures, prefixes: ["TG", "Tg"])
        return [average(cpu), average(gpu)].compactMap { $0 }.max()
    }

    private static func matching(_ temperatures: [String: Double], prefixes: [String]) -> [Double] {
        temperatures.compactMap { key, value in
            prefixes.contains(where: { key.hasPrefix($0) }) ? value : nil
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

public struct TemperatureMovingAverage: Sendable {
    private let sampleCount: Int
    private var samples: [Double] = []

    public init(sampleCount: Int) {
        precondition(sampleCount > 0)
        self.sampleCount = sampleCount
    }

    public mutating func add(_ temperature: Double) -> Double {
        samples.append(temperature)
        if samples.count > sampleCount {
            samples.removeFirst(samples.count - sampleCount)
        }
        return samples.reduce(0, +) / Double(samples.count)
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
