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

    func testBatteryAwakeSessionLifetime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(
            LidAwakePolicy.batteryAwakeSessionIsActive(
                until: nil,
                batteryPercent: 80,
                minimumPercent: 20,
                now: now
            )
        )
        XCTAssertFalse(
            LidAwakePolicy.batteryAwakeSessionIsActive(
                until: now.addingTimeInterval(-1),
                batteryPercent: 80,
                minimumPercent: 20,
                now: now
            )
        )
        XCTAssertTrue(
            LidAwakePolicy.batteryAwakeSessionIsActive(
                until: now.addingTimeInterval(600),
                batteryPercent: 80,
                minimumPercent: 20,
                now: now
            )
        )
        XCTAssertFalse(
            LidAwakePolicy.batteryAwakeSessionIsActive(
                until: now.addingTimeInterval(600),
                batteryPercent: 20,
                minimumPercent: 20,
                now: now
            )
        )
        XCTAssertTrue(
            LidAwakePolicy.batteryAwakeSessionIsActive(
                until: now.addingTimeInterval(600),
                batteryPercent: nil,
                minimumPercent: 20,
                now: now
            )
        )
    }

    func testActiveBatterySessionDisablesSleepExceptOnUnknownPower() {
        XCTAssertTrue(
            LidAwakePolicy.shouldDisableSleep(
                for: .battery,
                policyEnabled: true,
                batteryAwakeSessionActive: true
            )
        )
        XCTAssertFalse(
            LidAwakePolicy.shouldDisableSleep(
                for: .unknown,
                policyEnabled: true,
                batteryAwakeSessionActive: true
            )
        )
        XCTAssertTrue(
            LidAwakePolicy.shouldDisableSleep(
                for: .ac,
                policyEnabled: false,
                batteryAwakeSessionActive: true
            )
        )
        XCTAssertFalse(
            LidAwakePolicy.shouldDisableSleep(
                for: .battery,
                policyEnabled: true,
                batteryAwakeSessionActive: false
            )
        )
    }

    func testDecodesLegacyConfigurationWithoutBatterySessionFields() throws {
        let configuration = try JSONDecoder().decode(
            LidAwakeConfiguration.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        XCTAssertTrue(configuration.enabled)
        XCTAssertNil(configuration.batteryAwakeUntil)
        XCTAssertEqual(configuration.batteryAwakeMinimumPercent, 20)
    }

    func testConfigurationRoundTripPreservesBatteryAwakeUntil() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let until = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try encoder.encode(
            LidAwakeConfiguration(enabled: true, batteryAwakeUntil: until)
        )
        let decoded = try decoder.decode(LidAwakeConfiguration.self, from: data)
        let decodedUntil = try XCTUnwrap(decoded.batteryAwakeUntil)
        XCTAssertEqual(
            decodedUntil.timeIntervalSince1970,
            until.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(decoded.batteryAwakeMinimumPercent, 20)
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

    func testBatteryFlowResolutionUsesOnePointFiveWattThreshold() {
        XCTAssertEqual(
            LidAwakePolicy.resolvedBatteryFlow(
                systemLoadWatts: 30,
                externalInputWatts: 20,
                displayedBatteryWatts: 1,
                systemIsCharging: true
            ),
            .discharging
        )
        XCTAssertEqual(
            LidAwakePolicy.resolvedBatteryFlow(
                systemLoadWatts: 20,
                externalInputWatts: 50,
                displayedBatteryWatts: 1,
                systemIsCharging: false
            ),
            .charging
        )
        XCTAssertEqual(
            LidAwakePolicy.resolvedBatteryFlow(
                systemLoadWatts: 20,
                externalInputWatts: 22.5,
                displayedBatteryWatts: 1,
                systemIsCharging: false
            ),
            .idle
        )
        XCTAssertEqual(
            LidAwakePolicy.resolvedBatteryFlow(
                systemLoadWatts: nil,
                externalInputWatts: nil,
                displayedBatteryWatts: nil,
                systemIsCharging: false
            ),
            .idle
        )
    }

    func testBatteryFlowResolverRejectsUnsynchronizedSingleFrameEvidence() {
        var resolver = BatteryFlowResolver()
        let samples: [(system: Double, input: Double, battery: Double)] = [
            (14.453, 12.499, 0.524),
            (27.898, 30.707, 0.548),
            (30.707, 27.169, 0.549),
            (28.603, 39.812, 0.545),
            (39.812, 46.032, 0.618),
            (46.032, 41.950, 0.615),
            (35.986, 35.377, 0.597),
            (16.403, 18.741, 0.553),
            (18.741, 20.616, 0.590),
            (20.616, 32.200, 0.575),
            (32.200, 19.786, 0.576),
        ]

        for sample in samples {
            XCTAssertEqual(
                resolver.resolve(
                    systemLoadWatts: sample.system,
                    externalInputWatts: sample.input,
                    displayedBatteryWatts: sample.battery,
                    systemIsCharging: false,
                    isOnACPower: true
                ),
                .idle
            )
        }
    }

    func testBatteryFlowResolverConfirmsPersistentChangesAndHandlesACDisconnect() {
        var resolver = BatteryFlowResolver()
        XCTAssertEqual(
            resolver.resolve(
                systemLoadWatts: 20,
                externalInputWatts: 20,
                displayedBatteryWatts: 1,
                systemIsCharging: false,
                isOnACPower: true
            ),
            .idle
        )

        for sample in 1...3 {
            XCTAssertEqual(
                resolver.resolve(
                    systemLoadWatts: 20,
                    externalInputWatts: 50,
                    displayedBatteryWatts: 1,
                    systemIsCharging: false,
                    isOnACPower: true
                ),
                sample < 3 ? .idle : .charging
            )
        }

        XCTAssertEqual(
            resolver.resolve(
                systemLoadWatts: 40,
                externalInputWatts: 20,
                displayedBatteryWatts: 1,
                systemIsCharging: false,
                isOnACPower: true
            ),
            .charging
        )

        for sample in 1...3 {
            XCTAssertEqual(
                resolver.resolve(
                    systemLoadWatts: 20,
                    externalInputWatts: 20,
                    displayedBatteryWatts: 1,
                    systemIsCharging: false,
                    isOnACPower: true
                ),
                sample < 3 ? .charging : .idle
            )
        }

        XCTAssertEqual(
            resolver.resolve(
                systemLoadWatts: 40,
                externalInputWatts: 0,
                displayedBatteryWatts: 1,
                systemIsCharging: false,
                isOnACPower: false
            ),
            .discharging
        )
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
