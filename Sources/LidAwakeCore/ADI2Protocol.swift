import Foundation

/// The subset of RME's ADI-2 MIDI protocol (version 0.2, `MIDITable_ADI-2_230930`) that hardware
/// volume control needs. Payloads exclude the SysEx framing bytes `F0` / `F7`.
public enum ADI2Protocol {
    public static let deviceID: UInt8 = 0x71 // ADI-2 DAC; 0x72 is ADI-2 Pro, 0x73 ADI-2/4 Pro SE.

    private static let vendorID: [UInt8] = [0x00, 0x20, 0x0D]
    private static let sendToRemote: UInt8 = 0x01
    private static let sendToDevice: UInt8 = 0x02
    private static let request: UInt8 = 0x03
    private static let statusMessage: UInt8 = 0x07
    private static let allSettings: UInt8 = 0x09
    /// Address 12 and above use a different container layout and never carry output settings.
    private static let firstNonChannelAddress = 12

    /// Asks for a full settings dump. The first valid message also makes the device start sending
    /// status about once per second and report every parameter that changes on the unit.
    public static func requestAllSettingsPayload() -> [UInt8] {
        vendorID + [deviceID, request, allSettings]
    }

    public static func setPayload(_ parameters: [ADI2ChannelParameter]) -> [UInt8] {
        vendorID + [deviceID, sendToDevice] + parameters.flatMap(encode)
    }

    /// Channel container: byte 1 = address (bits 6..3) and index bits 4..2; byte 2 = index bits
    /// 1..0 (bits 6..5) and the upper five bits of a 12-bit two's complement value; byte 3 = the
    /// lower seven value bits.
    public static func encode(_ parameter: ADI2ChannelParameter) -> [UInt8] {
        let value = parameter.value & 0xFFF
        return [
            UInt8(((parameter.address & 0xF) << 3) | ((parameter.index >> 2) & 0x7)),
            UInt8(((parameter.index & 0x3) << 5) | ((value >> 7) & 0x1F)),
            UInt8(value & 0x7F),
        ]
    }

    public static func decode(_ bytes: ArraySlice<UInt8>) -> ADI2ChannelParameter? {
        guard bytes.count == 3 else { return nil }
        let first = Int(bytes[bytes.startIndex])
        let second = Int(bytes[bytes.startIndex + 1])
        let third = Int(bytes[bytes.startIndex + 2])
        let address = (first >> 3) & 0xF
        guard address < firstNonChannelAddress else { return nil }
        let index = ((first & 0x7) << 2) | ((second >> 5) & 0x3)
        let raw = ((second & 0x1F) << 7) | (third & 0x7F)
        return ADI2ChannelParameter(address: address, index: index, value: raw >= 2048 ? raw - 4096 : raw)
    }

    public static func parse(_ payload: [UInt8]) -> ADI2Message? {
        guard payload.count >= 5,
              Array(payload[0..<3]) == vendorID,
              payload[3] == deviceID else {
            return nil
        }
        switch payload[4] {
        case sendToRemote:
            var parameters: [ADI2ChannelParameter] = []
            var offset = 5
            while offset + 3 <= payload.count {
                if let parameter = decode(payload[offset..<offset + 3]) {
                    parameters.append(parameter)
                }
                offset += 3
            }
            return .parameters(parameters)
        case statusMessage:
            guard payload.count >= 6 else { return nil }
            return .status(activeOutput: ADI2Output(statusCode: Int(payload[5] & 0x3)))
        default:
            return nil
        }
    }
}

public struct ADI2ChannelParameter: Equatable, Sendable {
    public var address: Int
    public var index: Int
    public var value: Int

    public init(address: Int, index: Int, value: Int) {
        self.address = address
        self.index = index
        self.value = value
    }

    public static func volume(_ tenths: Int, on output: ADI2Output) -> Self {
        Self(address: output.rawValue, index: ADI2OutputParameter.volume.rawValue, value: tenths)
    }

    public static func mute(_ muted: Bool, on output: ADI2Output) -> Self {
        Self(address: output.rawValue, index: ADI2OutputParameter.mute.rawValue, value: muted ? 1 : 0)
    }
}

public enum ADI2Message: Equatable, Sendable {
    case parameters([ADI2ChannelParameter])
    case status(activeOutput: ADI2Output?)
}

/// Output channel addresses on the ADI-2 DAC.
public enum ADI2Output: Int, CaseIterable, Sendable {
    case line = 3
    case phones = 6
    case iem = 9

    /// Status byte bits 1..0 name the output the volume knob currently drives.
    public init?(statusCode: Int) {
        switch statusCode {
        case 0: self = .line
        case 1: self = .phones
        case 2: self = .iem
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .line: return "线路输出"
        case .phones: return "耳机"
        case .iem: return "IEM"
        }
    }
}

public enum ADI2OutputParameter: Int, Sendable {
    case volume = 12
    case lockVolume = 13
    case mute = 15
}

/// Volume travels in 0.1 dB units; the unit accepts -114.5 dB to +6.0 dB.
public enum ADI2Volume {
    public static let minimumTenths = -1145
    public static let maximumTenths = 60

    public static func clamped(_ tenths: Int) -> Int {
        min(max(tenths, minimumTenths), maximumTenths)
    }

    public static func stepped(_ tenths: Int, by deltaTenths: Int) -> Int {
        clamped(tenths + deltaTenths)
    }

    /// The unit's own knob moves in 0.5 dB steps, so slider input snaps to the same grid.
    public static func snappedToHalfDecibel(_ decibels: Double) -> Int {
        clamped(Int((decibels * 2).rounded()) * 5)
    }

    public static func text(_ tenths: Int) -> String {
        String(format: "%.1f dB", Double(tenths) / 10)
    }
}

/// Converts complete SysEx payloads to and from MIDI 1.0 Universal MIDI Packets (message type 3,
/// "Data 64"), which is what CoreMIDI's event-list API carries.
public enum UMPSysEx7 {
    private static let complete: UInt32 = 0
    private static let start: UInt32 = 1
    private static let continuation: UInt32 = 2
    private static let end: UInt32 = 3

    public static func words(for payload: [UInt8], group: UInt32 = 0) -> [UInt32] {
        let chunks = stride(from: 0, to: max(payload.count, 1), by: 6).map {
            Array(payload[$0..<min($0 + 6, payload.count)])
        }
        var words: [UInt32] = []
        for (position, chunk) in chunks.enumerated() {
            let status: UInt32
            if chunks.count == 1 {
                status = complete
            } else if position == 0 {
                status = start
            } else if position == chunks.count - 1 {
                status = end
            } else {
                status = continuation
            }
            var bytes = [UInt32](repeating: 0, count: 6)
            for (offset, byte) in chunk.enumerated() {
                bytes[offset] = UInt32(byte & 0x7F)
            }
            words.append(0x3000_0000 | (group & 0xF) << 24 | status << 20 | UInt32(chunk.count) << 16
                | bytes[0] << 8 | bytes[1])
            words.append(bytes[2] << 24 | bytes[3] << 16 | bytes[4] << 8 | bytes[5])
        }
        return words
    }

    /// Reassembles SysEx payloads from a stream of UMP words. Other message types are skipped.
    public struct Assembler: Sendable {
        private var buffer: [UInt8] = []
        private var pendingWord: UInt32?
        private var wordsToSkip = 0

        public init() {}

        public mutating func consume(_ words: some Sequence<UInt32>) -> [[UInt8]] {
            var payloads: [[UInt8]] = []
            for word in words {
                if wordsToSkip > 0 {
                    wordsToSkip -= 1
                } else if let first = pendingWord {
                    pendingWord = nil
                    if let payload = consume(first, word) {
                        payloads.append(payload)
                    }
                } else if word >> 28 == 0x3 {
                    pendingWord = word
                } else {
                    wordsToSkip = Self.wordCount(messageType: word >> 28) - 1
                }
            }
            return payloads
        }

        private static func wordCount(messageType: UInt32) -> Int {
            switch messageType {
            case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
            case 0xB, 0xC: return 3
            case 0x5, 0xD, 0xE, 0xF: return 4
            default: return 1
            }
        }

        private mutating func consume(_ first: UInt32, _ second: UInt32) -> [UInt8]? {
            let status = (first >> 20) & 0xF
            let count = min(Int((first >> 16) & 0xF), 6)
            let bytes = [
                UInt8((first >> 8) & 0x7F), UInt8(first & 0x7F),
                UInt8((second >> 24) & 0x7F), UInt8((second >> 16) & 0x7F),
                UInt8((second >> 8) & 0x7F), UInt8(second & 0x7F),
            ].prefix(count)
            switch status {
            case UMPSysEx7.complete:
                buffer = []
                return Array(bytes)
            case UMPSysEx7.start:
                buffer = Array(bytes)
            case UMPSysEx7.continuation:
                buffer += bytes
            case UMPSysEx7.end:
                let payload = buffer + bytes
                buffer = []
                return payload
            default:
                buffer = []
            }
            return nil
        }
    }
}
