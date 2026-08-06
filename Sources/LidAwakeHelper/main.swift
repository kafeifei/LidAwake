import CoreFoundation
import Darwin
import Foundation
import IOKit
import IOKit.ps
import LidAwakeCore

private enum HelperConstants {
    static let version = LidAwakeProtocol.helperVersion
    static let statusDirectory = LidAwakePaths.systemSupportDirectory
    static let statusPath = LidAwakePaths.statusPath
    static let pmsetPath = "/usr/bin/pmset"
}

private enum HelperArguments {
    static func configurationPath(in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--configuration"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        let path = arguments[flagIndex + 1]
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private struct PowerTelemetry {
    let adapterWatts: Int?
    let batteryWatts: Double?

    var batteryFlow: BatteryFlow {
        LidAwakePolicy.batteryFlow(forWatts: batteryWatts)
    }
}

private final class CommandRunner {
    func run(_ executable: String, arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, output: error.localizedDescription)
        }
    }
}

private final class StatusWriter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func write(_ status: HelperStatus) {
        do {
            try FileManager.default.createDirectory(
                atPath: HelperConstants.statusDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let data = try encoder.encode(status)
            try data.write(to: URL(fileURLWithPath: HelperConstants.statusPath), options: .atomic)
            chmod(HelperConstants.statusPath, 0o644)
        } catch {
            fputs("LidAwakeHelper: unable to write status: \(error)\n", stderr)
        }
    }
}

private final class PowerMonitor {
    private let configurationPath: String
    private let runner = CommandRunner()
    private let statusWriter = StatusWriter()
    private var notificationSource: CFRunLoopSource?
    private var timer: Timer?
    private var terminationSources: [DispatchSourceSignal] = []
    private var isReconciling = false

    init(configurationPath: String) {
        self.configurationPath = configurationPath
    }

    func start() {
        guard geteuid() == 0 else {
            statusWriter.write(HelperStatus(
                version: HelperConstants.version,
                mode: .error,
                powerSource: .unknown,
                sleepDisabled: nil,
                batteryFlow: .unknown,
                updatedAt: Date(),
                trigger: "startup",
                detail: "helper must run as root"
            ))
            exit(EXIT_FAILURE)
        }

        statusWriter.write(HelperStatus(
            version: HelperConstants.version,
            policyEnabled: readConfiguration().enabled,
            mode: .starting,
            powerSource: .unknown,
            sleepDisabled: readSleepDisabled(),
            updatedAt: Date(),
            trigger: "process-start"
        ))

        installSignalHandlers()
        installPowerSourceTrigger()
        installConfigurationTrigger()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reconcile(trigger: "timer")
        }

        reconcile(trigger: "startup")
        RunLoop.main.run()
    }

    private func installPowerSourceTrigger() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.reconcile(trigger: "power-source-event")
        }, context) else {
            statusWriter.write(HelperStatus(
                version: HelperConstants.version,
                policyEnabled: readConfiguration().enabled,
                mode: .error,
                powerSource: .unknown,
                sleepDisabled: readSleepDisabled(),
                batteryFlow: .unknown,
                updatedAt: Date(),
                trigger: "startup",
                detail: "unable to subscribe to power source events; timer fallback remains active"
            ))
            return
        }

        let source = unmanagedSource.takeRetainedValue()
        notificationSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreDefaultAndExit()
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    private func installConfigurationTrigger() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            context,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(observer).takeUnretainedValue()
                monitor.reconcile(trigger: "configuration-event")
            },
            LidAwakePaths.configurationChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func restoreDefaultAndExit() {
        _ = setSleepDisabled(false)
        exit(EXIT_SUCCESS)
    }

    private func reconcile(trigger: String) {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let powerSource = readPowerSource()
        let telemetry = readPowerTelemetry(powerSource: powerSource)
        let configuration = readConfiguration()
        let desiredSleepDisabled = LidAwakePolicy.shouldDisableSleep(
            for: powerSource,
            policyEnabled: configuration.enabled
        )
        var currentSleepDisabled = readSleepDisabled()
        var detail: String?

        if currentSleepDisabled != desiredSleepDisabled {
            let result = setSleepDisabled(desiredSleepDisabled)
            if result.exitCode != 0 {
                detail = "pmset failed: " + concise(result.output)
            }
            currentSleepDisabled = readSleepDisabled()
        }

        if powerSource == .unknown {
            let restoreResult = setSleepDisabled(false)
            currentSleepDisabled = readSleepDisabled()
            detail = restoreResult.exitCode == 0
                ? "unknown power source; restored normal sleep"
                : "unknown power source and restore failed: " + concise(restoreResult.output)
        }

        let matchesPolicy = currentSleepDisabled == desiredSleepDisabled
        let mode: HelperMode
        if powerSource == .unknown || !matchesPolicy {
            mode = .error
        } else {
            mode = desiredSleepDisabled ? .awake : .normal
        }

        statusWriter.write(HelperStatus(
            version: HelperConstants.version,
            policyEnabled: configuration.enabled,
            mode: mode,
            powerSource: powerSource,
            sleepDisabled: currentSleepDisabled,
            adapterWatts: telemetry.adapterWatts,
            batteryWatts: telemetry.batteryWatts,
            batteryFlow: telemetry.batteryFlow,
            updatedAt: Date(),
            trigger: trigger,
            detail: detail
        ))
    }

    private func readPowerSource() -> DetectedPowerSource {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return .unknown
        }

        let value = sourceType as String
        if value == kIOPSACPowerValue as String {
            return .ac
        }
        if value == kIOPSBatteryPowerValue as String {
            return .battery
        }
        return .unknown
    }

    private func readSleepDisabled() -> Bool? {
        let result = runner.run(HelperConstants.pmsetPath, arguments: ["-g"])
        guard result.exitCode == 0 else { return nil }
        return LidAwakePolicy.parseSleepDisabled(fromPMSetOutput: result.output)
    }

    private func readConfiguration() -> LidAwakeConfiguration {
        guard let data = FileManager.default.contents(atPath: configurationPath),
              let configuration = try? JSONDecoder().decode(LidAwakeConfiguration.self, from: data) else {
            return LidAwakeConfiguration(enabled: false)
        }
        return configuration
    }

    private func readPowerTelemetry(powerSource: DetectedPowerSource) -> PowerTelemetry {
        PowerTelemetry(
            adapterWatts: readAdapterWatts(),
            batteryWatts: readBatteryWatts(powerSource: powerSource)
        )
    }

    private func readAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details["Watts"] as? NSNumber else {
            return nil
        }
        return watts.intValue
    }

    private func readBatteryWatts(powerSource: DetectedPowerSource) -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
        let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any],
        let voltage = (properties["Voltage"] as? NSNumber)?.int64Value else {
            return nil
        }

        let currentNumber = (properties["InstantAmperage"] as? NSNumber)
            ?? (properties["Amperage"] as? NSNumber)
        guard let currentNumber else { return nil }

        var current = normalizedSignedMilliamps(currentNumber.int64Value)
        let isCharging = (properties["IsCharging"] as? NSNumber)?.boolValue ?? false
        if isCharging && current < 0 {
            current = abs(current)
        } else if powerSource == .battery && current > 0 {
            current = -current
        }

        return LidAwakePolicy.batteryWatts(
            voltageMillivolts: voltage,
            currentMilliamps: current
        )
    }

    private func normalizedSignedMilliamps(_ rawValue: Int64) -> Int64 {
        if rawValue > Int64(Int16.max), rawValue <= Int64(UInt16.max) {
            return Int64(Int16(bitPattern: UInt16(rawValue)))
        }
        return rawValue
    }

    private func setSleepDisabled(_ disabled: Bool) -> CommandResult {
        runner.run(HelperConstants.pmsetPath, arguments: ["disablesleep", disabled ? "1" : "0"])
    }

    private func concise(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(240))
    }
}

if CommandLine.arguments.contains("--version") {
    print(HelperConstants.version)
    exit(EXIT_SUCCESS)
}

guard let configurationPath = HelperArguments.configurationPath(in: CommandLine.arguments) else {
    fputs("LidAwakeHelper: missing or invalid --configuration path\n", stderr)
    exit(EXIT_FAILURE)
}

PowerMonitor(configurationPath: configurationPath).start()
