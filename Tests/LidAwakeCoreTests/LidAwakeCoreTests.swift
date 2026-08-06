import XCTest
@testable import LidAwakeCore

final class LidAwakeCoreTests: XCTestCase {
    func testConfigurationPathUsesProvidedHomeDirectory() {
        XCTAssertEqual(
            LidAwakePaths.configurationPath(
                inHomeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
            ),
            "/Users/example/Library/Application Support/LidAwake/config.json"
        )
    }

    func testRendersPortableHelperConfigurationPath() throws {
        let template: [String: Any] = [
            "Label": LidAwakeProtocol.helperLabel,
            "ProgramArguments": [
                "/Library/PrivilegedHelperTools/\(LidAwakeProtocol.helperLabel)",
                "--configuration",
                HelperPlistRenderer.configurationPlaceholder,
            ],
        ]
        let templateData = try PropertyListSerialization.data(
            fromPropertyList: template,
            format: .xml,
            options: 0
        )

        let renderedData = try HelperPlistRenderer.render(
            templateData: templateData,
            configurationPath: "/Users/example/Library/Application Support/LidAwake/config.json"
        )
        let rendered = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: renderedData, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(rendered["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.last, "/Users/example/Library/Application Support/LidAwake/config.json")
        XCTAssertFalse(arguments.contains(HelperPlistRenderer.configurationPlaceholder))
    }

    func testRejectsRelativeHelperConfigurationPath() throws {
        let template = try PropertyListSerialization.data(
            fromPropertyList: [
                "ProgramArguments": [HelperPlistRenderer.configurationPlaceholder],
            ],
            format: .xml,
            options: 0
        )

        XCTAssertThrowsError(
            try HelperPlistRenderer.render(
                templateData: template,
                configurationPath: "relative/config.json"
            )
        )
    }

    func testACDisablesSleep() {
        XCTAssertTrue(LidAwakePolicy.shouldDisableSleep(for: .ac))
        XCTAssertFalse(LidAwakePolicy.shouldDisableSleep(for: .ac, policyEnabled: false))
    }

    func testBatteryAndUnknownRestoreNormalSleep() {
        XCTAssertFalse(LidAwakePolicy.shouldDisableSleep(for: .battery))
        XCTAssertFalse(LidAwakePolicy.shouldDisableSleep(for: .unknown))
    }

    func testParsesSleepDisabledFromPMSetOutput() {
        XCTAssertEqual(
            LidAwakePolicy.parseSleepDisabled(fromPMSetOutput: "System-wide power settings:\n SleepDisabled\t\t1\n"),
            true
        )
        XCTAssertEqual(
            LidAwakePolicy.parseSleepDisabled(fromPMSetOutput: "System-wide power settings:\n SleepDisabled 0\n"),
            false
        )
        XCTAssertNil(LidAwakePolicy.parseSleepDisabled(fromPMSetOutput: "Currently in use:\n sleep 1\n"))
    }

    func testBatteryPowerSignAndFlow() {
        XCTAssertEqual(
            LidAwakePolicy.batteryWatts(voltageMillivolts: 12_000, currentMilliamps: 1_000),
            12,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LidAwakePolicy.batteryWatts(voltageMillivolts: 12_000, currentMilliamps: -1_000),
            -12,
            accuracy: 0.001
        )
        XCTAssertEqual(LidAwakePolicy.batteryFlow(forWatts: 10), .charging)
        XCTAssertEqual(LidAwakePolicy.batteryFlow(forWatts: -10), .discharging)
        XCTAssertEqual(LidAwakePolicy.batteryFlow(forWatts: 0), .idle)
        XCTAssertEqual(LidAwakePolicy.batteryFlow(forWatts: nil), .unknown)
    }

    func testChargeTimeUsesConfiguredTarget() {
        XCTAssertEqual(
            BatteryChargeTimeEstimator.minutesToTarget(
                currentPercentage: 60,
                targetPercentage: 80,
                systemMinutesToFull: 120
            ),
            60
        )
        XCTAssertEqual(
            BatteryChargeTimeEstimator.minutesToTarget(
                currentPercentage: 60,
                targetPercentage: 100,
                systemMinutesToFull: 120
            ),
            120
        )
        XCTAssertEqual(
            BatteryChargeTimeEstimator.minutesToTarget(
                currentPercentage: 85,
                targetPercentage: 85,
                systemMinutesToFull: 120
            ),
            0
        )
        XCTAssertNil(
            BatteryChargeTimeEstimator.minutesToTarget(
                currentPercentage: 60,
                targetPercentage: 85,
                systemMinutesToFull: nil
            )
        )
    }
}
