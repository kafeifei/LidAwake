import XCTest
@testable import LidAwakeCore

final class ADI2ProtocolTests: XCTestCase {
    /// RME's own example (address 9, index 12, -10 dB), framed for the ADI-2 DAC.
    func testEncodesVolumeLikeRMEExample() {
        XCTAssertEqual(ADI2Protocol.encode(.volume(-100, on: .iem)), [0x4B, 0x1F, 0x1C])
    }

    /// Bytes captured while setting the IEM output to -25.0 dB on a real ADI-2 DAC FS.
    func testBuildsSetVolumePayload() {
        XCTAssertEqual(
            ADI2Protocol.setPayload([.volume(-250, on: .iem)]),
            [0x00, 0x20, 0x0D, 0x71, 0x02, 0x4B, 0x1E, 0x06]
        )
    }

    func testRequestAllSettingsPayload() {
        XCTAssertEqual(ADI2Protocol.requestAllSettingsPayload(), [0x00, 0x20, 0x0D, 0x71, 0x03, 0x09])
    }

    func testChannelParametersRoundTrip() {
        for output in ADI2Output.allCases {
            for value in [ADI2Volume.minimumTenths, -205, -1, 0, 1, ADI2Volume.maximumTenths] {
                let parameter = ADI2ChannelParameter.volume(value, on: output)
                XCTAssertEqual(ADI2Protocol.decode(ADI2Protocol.encode(parameter)[...]), parameter)
            }
            let mute = ADI2ChannelParameter.mute(true, on: output)
            XCTAssertEqual(ADI2Protocol.decode(ADI2Protocol.encode(mute)[...]), mute)
        }
    }

    func testParsesParameterDumpAndSkipsDeviceSettings() {
        // Line volume -20.5 dB, a device-scope container (address 12), IEM mute on.
        let payload: [UInt8] = [0x00, 0x20, 0x0D, 0x71, 0x01]
            + ADI2Protocol.encode(.volume(-205, on: .line))
            + [0x60, 0x10, 0x01]
            + ADI2Protocol.encode(.mute(true, on: .iem))
        XCTAssertEqual(
            ADI2Protocol.parse(payload),
            .parameters([.volume(-205, on: .line), .mute(true, on: .iem)])
        )
    }

    func testParsesStatusActiveOutput() {
        let status: [UInt8] = [0x00, 0x20, 0x0D, 0x71, 0x07, 0x06, 0x12, 0x5E, 0x38, 0x48, 0x00, 0x00]
        XCTAssertEqual(ADI2Protocol.parse(status), .status(activeOutput: .iem))
        var line = status
        line[5] = 0x04
        XCTAssertEqual(ADI2Protocol.parse(line), .status(activeOutput: .line))
    }

    func testIgnoresOtherDevicesAndVendors() {
        XCTAssertNil(ADI2Protocol.parse([0x00, 0x20, 0x0D, 0x73, 0x07, 0x02]))
        XCTAssertNil(ADI2Protocol.parse([0x00, 0x21, 0x0D, 0x71, 0x07, 0x02]))
        XCTAssertNil(ADI2Protocol.parse([0x00, 0x20]))
    }

    func testVolumeStepsStayInRange() {
        XCTAssertEqual(ADI2Volume.stepped(-245, by: 10), -235)
        XCTAssertEqual(ADI2Volume.stepped(55, by: 10), ADI2Volume.maximumTenths)
        XCTAssertEqual(ADI2Volume.stepped(-1140, by: -10), ADI2Volume.minimumTenths)
        XCTAssertEqual(ADI2Volume.snappedToHalfDecibel(-24.3), -245)
        XCTAssertEqual(ADI2Volume.snappedToHalfDecibel(-24.2), -240)
        XCTAssertEqual(ADI2Volume.snappedToHalfDecibel(12), ADI2Volume.maximumTenths)
        XCTAssertEqual(ADI2Volume.text(-245), "-24.5 dB")
    }

    func testKeyStepsLandOnTheirGrid() {
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-240, by: 40), -200)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-240, by: -40), -280)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-235, by: 40), -200)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-235, by: -40), -240)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-235, by: 10), -230)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-235, by: -10), -240)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(25, by: 40), 40)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(45, by: 40), ADI2Volume.maximumTenths)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(ADI2Volume.maximumTenths, by: -40), 40)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(-1130, by: -40), ADI2Volume.minimumTenths)
        XCTAssertEqual(ADI2Volume.steppedOnGrid(ADI2Volume.minimumTenths, by: 40), -1120)
    }

    func testUMPSysExRoundTripsShortAndLongPayloads() {
        for length in [0, 3, 6, 7, 12, 13, 250] {
            let payload = (0..<length).map { UInt8($0 % 128) }
            let words = UMPSysEx7.words(for: payload)
            var assembler = UMPSysEx7.Assembler()
            XCTAssertEqual(assembler.consume(words), [payload], "length \(length)")
        }
    }

    func testUMPSysExEncodingMatchesSpecLayout() {
        // An 8-byte payload: a start packet with six bytes, then an end packet with two.
        let words = UMPSysEx7.words(for: [0x00, 0x20, 0x0D, 0x71, 0x03, 0x09, 0x01, 0x02])
        XCTAssertEqual(words, [0x3016_0020, 0x0D71_0309, 0x3032_0102, 0x0000_0000])
    }

    func testAssemblerSkipsInterleavedNonSysExMessages() {
        let payload: [UInt8] = [0x00, 0x20, 0x0D, 0x71, 0x07, 0x06, 0x12, 0x5E]
        let sysex = UMPSysEx7.words(for: payload)
        let noteOn: UInt32 = 0x2090_3C64
        let midi2Note: [UInt32] = [0x4090_3C00, 0xFFFF_0000]
        var assembler = UMPSysEx7.Assembler()
        XCTAssertEqual(assembler.consume([noteOn] + midi2Note + sysex + [noteOn]), [payload])
    }
}
