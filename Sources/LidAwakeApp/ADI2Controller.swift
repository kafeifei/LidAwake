import CoreAudio
import CoreMIDI
import Foundation
import LidAwakeCore

/// Talks to an RME ADI-2 DAC over its USB MIDI port, the same channel RME's ADI-2 Remote uses.
/// Only control messages travel here; the audio stream is untouched, so volume is applied inside
/// the DAC exactly as when the knob is turned.
final class ADI2Controller {
    struct OutputState {
        var volumeTenths: Int?
        var muted = false
        var locked = false
    }

    private static let endpointNamePrefix = "ADI-2 DAC"
    /// The unit reports status about once a second after any valid message; silence longer than
    /// this means it restarted or stopped listening, so the request is sent again.
    private static let silenceBeforeRerequest: TimeInterval = 5
    /// Reports that arrive this soon after LidAwake set a level are taken as the unit catching up
    /// with that change, not as the knob being turned.
    private static let localChangeSettleTime: TimeInterval = 1

    private(set) var isConnected = false
    private(set) var activeOutput: ADI2Output?
    private(set) var outputs: [ADI2Output: OutputState] = [:]
    /// Called on the main queue whenever the connection or any tracked value changes.
    var onChange: (() -> Void)?
    /// Called on the main queue when the unit reports a new level or mute state for the output its
    /// knob drives, which is what turning or pressing the knob produces.
    var onKnobChange: ((ADI2Output) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private var assembler = UMPSysEx7.Assembler()
    private var lastMessageAt: Date?
    private var lastRequestAt: Date?
    private var lastLocalChangeAt: Date?
    /// Outputs whose mute state the unit has reported at least once; `OutputState.muted` defaults
    /// to false, which cannot tell a first report from a change.
    private var reportedMute: Set<ADI2Output> = []

    init() {
        let clientStatus = MIDIClientCreateWithBlock("LidAwake" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connect() }
        }
        guard clientStatus == noErr else {
            reportFailure("无法创建 MIDI 客户端", status: clientStatus)
            return
        }
        MIDIOutputPortCreate(client, "LidAwake ADI-2 out" as CFString, &outputPort)
        MIDIInputPortCreateWithProtocol(client, "LidAwake ADI-2 in" as CFString, ._1_0, &inputPort) {
            [weak self] eventList, _ in
            let words = Self.words(in: eventList)
            DispatchQueue.main.async { self?.receive(words) }
        }
        connect()
    }

    var activeState: OutputState? {
        activeOutput.flatMap { outputs[$0] }
    }

    /// Rescans the MIDI endpoints; called at launch and whenever the MIDI setup changes.
    func connect() {
        let newSource = Self.endpoint(count: MIDIGetNumberOfSources(), at: MIDIGetSource)
        let newDestination = Self.endpoint(count: MIDIGetNumberOfDestinations(), at: MIDIGetDestination)
        guard newSource != source || newDestination != destination else { return }

        if source != 0 {
            MIDIPortDisconnectSource(inputPort, source)
        }
        source = newSource ?? 0
        destination = newDestination ?? 0
        assembler = UMPSysEx7.Assembler()
        outputs = [:]
        reportedMute = []
        activeOutput = nil
        lastMessageAt = nil
        isConnected = source != 0 && destination != 0
        if isConnected {
            MIDIPortConnectSource(inputPort, source, nil)
            requestSettings()
        }
        onChange?()
    }

    /// Driven by the app's one-second timer.
    func tick() {
        guard isConnected else { return }
        let reference = lastMessageAt ?? .distantPast
        let lastRequest = lastRequestAt ?? .distantPast
        if Date().timeIntervalSince(reference) > Self.silenceBeforeRerequest,
           Date().timeIntervalSince(lastRequest) > Self.silenceBeforeRerequest {
            requestSettings()
        }
    }

    func setVolume(_ tenths: Int, on output: ADI2Output) {
        let value = ADI2Volume.clamped(tenths)
        var parameters = [ADI2ChannelParameter.volume(value, on: output)]
        // Like the system volume keys, changing the level ends a mute.
        if outputs[output]?.muted == true {
            parameters.append(.mute(false, on: output))
            outputs[output]?.muted = false
        }
        outputs[output, default: OutputState()].volumeTenths = value
        lastLocalChangeAt = Date()
        send(ADI2Protocol.setPayload(parameters))
        onChange?()
    }

    func setMuted(_ muted: Bool, on output: ADI2Output) {
        outputs[output, default: OutputState()].muted = muted
        lastLocalChangeAt = Date()
        send(ADI2Protocol.setPayload([.mute(muted, on: output)]))
        onChange?()
    }

    private func requestSettings() {
        lastRequestAt = Date()
        send(ADI2Protocol.requestAllSettingsPayload())
    }

    private func receive(_ words: [UInt32]) {
        var changed = false
        var knobTurned = false
        for payload in assembler.consume(words) {
            guard let message = ADI2Protocol.parse(payload) else { continue }
            lastMessageAt = Date()
            switch message {
            case .status(let output):
                if output != activeOutput {
                    activeOutput = output
                    changed = true
                }
            case .parameters(let parameters):
                for parameter in parameters {
                    let change = apply(parameter)
                    changed = change.any || changed
                    if change.level, ADI2Output(rawValue: parameter.address) == activeOutput {
                        knobTurned = true
                    }
                }
            }
        }
        if changed {
            onChange?()
        }
        let settled = lastLocalChangeAt.map { Date().timeIntervalSince($0) > Self.localChangeSettleTime } ?? true
        if knobTurned, settled, let activeOutput {
            onKnobChange?(activeOutput)
        }
    }

    /// `level` is true only when an already known volume or mute state changed; the first report
    /// after connecting fills the values in without counting as a knob turn.
    private func apply(_ parameter: ADI2ChannelParameter) -> (any: Bool, level: Bool) {
        guard let output = ADI2Output(rawValue: parameter.address),
              let kind = ADI2OutputParameter(rawValue: parameter.index) else {
            return (false, false)
        }
        var state = outputs[output] ?? OutputState()
        switch kind {
        case .volume: state.volumeTenths = parameter.value
        case .mute: state.muted = parameter.value != 0
        case .lockVolume: state.locked = parameter.value != 0
        }
        let previous = outputs[output]
        outputs[output] = state
        let volumeChanged = previous?.volumeTenths != state.volumeTenths
        let muteChanged = previous?.muted != state.muted
        var level = previous?.volumeTenths != nil && volumeChanged
        if kind == .mute {
            level = level || (reportedMute.contains(output) && muteChanged)
            reportedMute.insert(output)
        }
        return (volumeChanged || muteChanged || previous?.locked != state.locked, level)
    }

    private func send(_ payload: [UInt8]) {
        guard isConnected else { return }
        let words = UMPSysEx7.words(for: payload)
        // Each SysEx7 packet is two words; a generous buffer holds every message this app sends.
        let byteCount = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { buffer.deallocate() }
        let eventList = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var packet: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(eventList, ._1_0)
        for start in stride(from: 0, to: words.count, by: 2) {
            let pair = Array(words[start..<min(start + 2, words.count)])
            guard let current = packet else { break }
            packet = MIDIEventListAdd(eventList, byteCount, current, 0, pair.count, pair)
        }
        guard packet != nil else {
            reportFailure("MIDI 消息过长", status: -1)
            return
        }
        let status = MIDISendEventList(outputPort, destination, eventList)
        if status != noErr {
            reportFailure("无法发送 MIDI 消息", status: status)
        }
    }

    private func reportFailure(_ message: String, status: OSStatus) {
        FileHandle.standardError.write(Data("LidAwake: \(message)（\(status)）\n".utf8))
    }

    /// Reads every packet's words straight from the list: a packet may hold more words than the
    /// fixed-size tuple in `MIDIEventPacket`, so copying `pointee` could truncate it.
    private static func words(in eventList: UnsafePointer<MIDIEventList>) -> [UInt32] {
        var words: [UInt32] = []
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \MIDIEventPacket.words) ?? 12
        for packet in eventList.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let start = UnsafeRawPointer(packet).advanced(by: wordsOffset)
            for index in 0..<count {
                words.append(start.load(fromByteOffset: index * 4, as: UInt32.self))
            }
        }
        return words
    }

    private static func endpoint(
        count: Int,
        at endpoint: (Int) -> MIDIEndpointRef
    ) -> MIDIEndpointRef? {
        for index in 0..<count {
            let candidate = endpoint(index)
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(candidate, kMIDIPropertyDisplayName, &name) == noErr,
                  let displayName = name?.takeRetainedValue() as String?,
                  displayName.hasPrefix(endpointNamePrefix) else {
                continue
            }
            return candidate
        }
        return nil
    }
}

/// The volume keys are only redirected while the ADI-2 is the Mac's default output, so they keep
/// working normally for built-in speakers, AirPods and every other device.
enum DefaultOutputDevice {
    static func isADI2DAC() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return false
        }

        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let deviceName = name?.takeRetainedValue() as String? else {
            return false
        }
        return deviceName.hasPrefix("ADI-2 DAC")
    }
}
