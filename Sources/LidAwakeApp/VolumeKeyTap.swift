import AppKit
import ApplicationServices

enum VolumeKey {
    case up
    case down
    case mute
}

/// Intercepts the keyboard's volume keys with a session event tap. Only an active tap can swallow
/// a key, which is what keeps macOS from showing its own "volume unavailable" HUD, and an active
/// tap needs the Accessibility permission.
final class VolumeKeyTap {
    // Media keys arrive as NX_SYSDEFINED events with subtype NX_SUBTYPE_AUX_CONTROL_BUTTONS.
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private static let auxControlButtonsSubtype: Int16 = 8
    private static let keyDownState = 0xA

    /// Decides for every volume key event whether LidAwake handles it. Returning false lets the
    /// event continue to macOS untouched. `isKeyDown` is false for the matching key-up event,
    /// which is swallowed or passed on together with its key-down.
    var handler: ((_ key: VolumeKey, _ isKeyDown: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Returns false while the Accessibility permission is missing; callers retry later.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.isTrusted else { return false }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let keyTap = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return keyTap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system turns a slow or interrupted tap off; it has to be switched back on.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = (data & 0xFFFF_0000) >> 16
        let keyState = (data & 0xFF00) >> 8
        let key: VolumeKey
        switch Int32(keyCode) {
        case NX_KEYTYPE_SOUND_UP: key = .up
        case NX_KEYTYPE_SOUND_DOWN: key = .down
        case NX_KEYTYPE_MUTE: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        let handled = handler?(key, keyState == Self.keyDownState, nsEvent.modifierFlags) ?? false
        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
