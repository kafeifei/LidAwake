import Foundation

public enum LidAwakeProtocol {
    public static let helperVersion = 5
    public static let helperLabel = "com.kafeifei.LidAwake.helper"
}

public enum DetectedPowerSource: String, Codable, Sendable {
    case ac
    case battery
    case unknown
}

public enum HelperMode: String, Codable, Sendable {
    case starting
    case awake
    case normal
    case error
}

public enum LidAwakePaths {
    public static let applicationSupportDirectoryName = "LidAwake"
    public static let configurationFileName = "config.json"
    public static let systemSupportDirectory = "/Library/Application Support/LidAwake"
    public static let statusPath = systemSupportDirectory + "/status.json"
    public static let configurationChangedNotification = "com.kafeifei.LidAwake.configurationChanged"

    public static var configurationPath: String {
        configurationPath(inHomeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func configurationPath(inHomeDirectory homeDirectory: URL) -> String {
        homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(configurationFileName, isDirectory: false)
            .path
    }
}

public enum HelperPlistRendererError: LocalizedError {
    case invalidTemplate
    case invalidConfigurationPath

    public var errorDescription: String? {
        switch self {
        case .invalidTemplate:
            return "后台服务配置模板无效"
        case .invalidConfigurationPath:
            return "后台服务配置路径无效"
        }
    }
}

public enum HelperPlistRenderer {
    public static let configurationPlaceholder = "__LIDAWAKE_CONFIGURATION_PATH__"

    public static func render(templateData: Data, configurationPath: String) throws -> Data {
        guard configurationPath.hasPrefix("/"), !configurationPath.contains("\0") else {
            throw HelperPlistRendererError.invalidConfigurationPath
        }
        guard var plist = try PropertyListSerialization.propertyList(
            from: templateData,
            options: [],
            format: nil
        ) as? [String: Any],
        var arguments = plist["ProgramArguments"] as? [String],
        let placeholderIndex = arguments.firstIndex(of: configurationPlaceholder) else {
            throw HelperPlistRendererError.invalidTemplate
        }

        arguments[placeholderIndex] = URL(fileURLWithPath: configurationPath).standardizedFileURL.path
        plist["ProgramArguments"] = arguments
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }
}

public struct LidAwakeConfiguration: Codable, Sendable {
    public var enabled: Bool
    /// Expiry of the time-boxed "keep awake on battery" session; nil when no session was started.
    public var batteryAwakeUntil: Date?
    /// The battery session ends as soon as the charge drops to this percentage.
    public var batteryAwakeMinimumPercent: Int

    public init(
        enabled: Bool = true,
        batteryAwakeUntil: Date? = nil,
        batteryAwakeMinimumPercent: Int = 20
    ) {
        self.enabled = enabled
        self.batteryAwakeUntil = batteryAwakeUntil
        self.batteryAwakeMinimumPercent = batteryAwakeMinimumPercent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        batteryAwakeUntil = try container.decodeIfPresent(Date.self, forKey: .batteryAwakeUntil)
        batteryAwakeMinimumPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .batteryAwakeMinimumPercent
        ) ?? 20
    }
}

public enum BatteryAwakeStopReason: String, Codable, Sendable {
    case expired
    case lowBattery
}

public enum BatteryFlow: String, Codable, Sendable {
    case charging
    case discharging
    case idle
    case unknown
}

public struct HelperStatus: Codable, Sendable {
    public let version: Int
    public let policyEnabled: Bool
    public let mode: HelperMode
    public let powerSource: DetectedPowerSource
    public let sleepDisabled: Bool?
    public let adapterWatts: Int?
    public let batteryWatts: Double?
    public let batteryFlow: BatteryFlow
    /// Expiry of the active battery session; nil when no session is running.
    public let batteryAwakeUntil: Date?
    /// Why the configured battery session is not running; nil when there is none or it is active.
    public let batteryAwakeStopReason: BatteryAwakeStopReason?
    public let updatedAt: Date
    public let trigger: String
    public let detail: String?

    public init(
        version: Int,
        policyEnabled: Bool = true,
        mode: HelperMode,
        powerSource: DetectedPowerSource,
        sleepDisabled: Bool?,
        adapterWatts: Int? = nil,
        batteryWatts: Double? = nil,
        batteryFlow: BatteryFlow = .unknown,
        batteryAwakeUntil: Date? = nil,
        batteryAwakeStopReason: BatteryAwakeStopReason? = nil,
        updatedAt: Date,
        trigger: String,
        detail: String? = nil
    ) {
        self.version = version
        self.policyEnabled = policyEnabled
        self.mode = mode
        self.powerSource = powerSource
        self.sleepDisabled = sleepDisabled
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.batteryFlow = batteryFlow
        self.batteryAwakeUntil = batteryAwakeUntil
        self.batteryAwakeStopReason = batteryAwakeStopReason
        self.updatedAt = updatedAt
        self.trigger = trigger
        self.detail = detail
    }
}

public enum LidAwakePolicy {
    public static func shouldDisableSleep(
        for powerSource: DetectedPowerSource,
        policyEnabled: Bool = true
    ) -> Bool {
        shouldDisableSleep(
            for: powerSource,
            policyEnabled: policyEnabled,
            batteryAwakeSessionActive: false
        )
    }

    /// The battery session is independent of `policyEnabled`, which only covers AC power.
    /// An undetectable power source always restores normal sleep.
    public static func shouldDisableSleep(
        for powerSource: DetectedPowerSource,
        policyEnabled: Bool,
        batteryAwakeSessionActive: Bool
    ) -> Bool {
        (policyEnabled && powerSource == .ac)
            || (batteryAwakeSessionActive && powerSource != .unknown)
    }

    /// An unknown battery percentage keeps the session alive; the helper's
    /// "unknown power source restores sleep" path still guards the dangerous case.
    public static func batteryAwakeSessionIsActive(
        until: Date?,
        batteryPercent: Int?,
        minimumPercent: Int,
        now: Date
    ) -> Bool {
        guard let until, until > now else { return false }
        if let batteryPercent, batteryPercent <= minimumPercent { return false }
        return true
    }

    public static func parseSleepDisabled(fromPMSetOutput output: String) -> Bool? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2, fields[0].caseInsensitiveCompare("SleepDisabled") == .orderedSame else {
                continue
            }

            switch fields[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }

        return nil
    }

    public static func batteryWatts(voltageMillivolts: Int64, currentMilliamps: Int64) -> Double {
        Double(voltageMillivolts) * Double(currentMilliamps) / 1_000_000
    }

    public static func batteryFlow(forWatts watts: Double?) -> BatteryFlow {
        guard let watts else { return .unknown }
        if watts > 0.05 { return .charging }
        if watts < -0.05 { return .discharging }
        return .idle
    }

    public static func resolvedBatteryFlow(
        systemLoadWatts: Double?,
        externalInputWatts: Double?,
        displayedBatteryWatts: Double?,
        systemIsCharging: Bool,
        thresholdWatts: Double = 1.5
    ) -> BatteryFlow {
        guard let systemLoadWatts, let externalInputWatts else {
            return systemIsCharging ? .charging : .idle
        }

        if systemLoadWatts - externalInputWatts > thresholdWatts {
            return .discharging
        }

        if let displayedBatteryWatts,
           externalInputWatts - systemLoadWatts - abs(displayedBatteryWatts) > thresholdWatts {
            return .charging
        }

        return systemIsCharging ? .charging : .idle
    }
}

public struct BatteryFlowResolver {
    public let confirmationSamples: Int

    private var confirmedFlow: BatteryFlow?
    private var candidateFlow: BatteryFlow?
    private var candidateSamples = 0

    public init(confirmationSamples: Int = 3) {
        self.confirmationSamples = max(1, confirmationSamples)
    }

    public mutating func resolve(
        systemLoadWatts: Double?,
        externalInputWatts: Double?,
        displayedBatteryWatts: Double?,
        systemIsCharging: Bool,
        isOnACPower: Bool
    ) -> BatteryFlow {
        guard isOnACPower else {
            confirmedFlow = .discharging
            candidateFlow = nil
            candidateSamples = 0
            return .discharging
        }

        if confirmedFlow == nil {
            confirmedFlow = systemIsCharging ? .charging : .idle
        }

        let observedFlow = LidAwakePolicy.resolvedBatteryFlow(
            systemLoadWatts: systemLoadWatts,
            externalInputWatts: externalInputWatts,
            displayedBatteryWatts: displayedBatteryWatts,
            systemIsCharging: systemIsCharging
        )

        guard observedFlow != confirmedFlow else {
            candidateFlow = nil
            candidateSamples = 0
            return confirmedFlow!
        }

        if candidateFlow == observedFlow {
            candidateSamples += 1
        } else {
            candidateFlow = observedFlow
            candidateSamples = 1
        }

        if candidateSamples >= confirmationSamples {
            confirmedFlow = observedFlow
            candidateFlow = nil
            candidateSamples = 0
        }

        return confirmedFlow!
    }
}

public enum BatteryChargeTimeEstimator {
    /// Converts the system estimate for reaching 100% into an estimate for the
    /// configured charge target, rounding up to avoid promising an early finish.
    public static func minutesToTarget(
        currentPercentage: Int,
        targetPercentage: Int,
        systemMinutesToFull: Int?
    ) -> Int? {
        guard let systemMinutesToFull, systemMinutesToFull > 0 else { return nil }

        let current = min(max(currentPercentage, 0), 100)
        let target = min(max(targetPercentage, 0), 100)
        guard current < target else { return 0 }
        guard target < 100 else { return systemMinutesToFull }

        let fraction = Double(target - current) / Double(100 - current)
        return max(1, Int((Double(systemMinutesToFull) * fraction).rounded(.up)))
    }
}
