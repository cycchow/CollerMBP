import Foundation

public enum CoolingMode: String, Codable, CaseIterable, Sendable {
    case appleAuto
    case coolSurface
    case maximum

    public var displayName: String {
        switch self {
        case .appleAuto: return "Apple Automatic"
        case .coolSurface: return "Cool Surface"
        case .maximum: return "Maximum"
        }
    }
}

public struct FanReading: Codable, Hashable, Sendable {
    public let index: Int
    public let actualRPM: Int
    public let targetRPM: Int
    public let minRPM: Int
    public let maxRPM: Int
    public let mode: String
    public let modeKey: String?

    public init(index: Int, actualRPM: Int, targetRPM: Int, minRPM: Int, maxRPM: Int, mode: String, modeKey: String? = nil) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
        self.modeKey = modeKey
    }
}

public struct DaemonStatus: Codable, Sendable {
    public let timestamp: Date
    public let mode: CoolingMode
    public let controlTemperature: Double?
    public let cpuPeakTemperature: Double?
    public let gpuPeakTemperature: Double?
    public let hottestSensorTemperature: Double?
    public let thermalState: String
    public let targetCoolingLevel: Double?
    public let fans: [FanReading]
    public let temperatures: [String: Double]
    public let hardwareInfo: String
    public let lastError: String?
    public let recoveryRequired: Bool?

    public init(
        timestamp: Date,
        mode: CoolingMode,
        controlTemperature: Double?,
        cpuPeakTemperature: Double?,
        gpuPeakTemperature: Double?,
        hottestSensorTemperature: Double?,
        thermalState: String,
        targetCoolingLevel: Double?,
        fans: [FanReading],
        temperatures: [String: Double],
        hardwareInfo: String,
        lastError: String?,
        recoveryRequired: Bool? = false
    ) {
        self.timestamp = timestamp
        self.mode = mode
        self.controlTemperature = controlTemperature
        self.cpuPeakTemperature = cpuPeakTemperature
        self.gpuPeakTemperature = gpuPeakTemperature
        self.hottestSensorTemperature = hottestSensorTemperature
        self.thermalState = thermalState
        self.targetCoolingLevel = targetCoolingLevel
        self.fans = fans
        self.temperatures = temperatures
        self.hardwareInfo = hardwareInfo
        self.lastError = lastError
        self.recoveryRequired = recoveryRequired
    }
}

public struct DaemonConfig: Codable, Sendable {
    public var mode: CoolingMode

    public init(mode: CoolingMode = .appleAuto) {
        self.mode = mode
    }
}
