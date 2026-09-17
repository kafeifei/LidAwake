import AppKit
import CoreGraphics
import Foundation
import IOKit

/// Watches `IOPMrootDomain`'s `AppleClamshellState` and reports the moment the lid closes.
/// The notification only says "something about this service changed", so every message
/// re-reads the property and the transition is derived here.
final class ClamshellMonitor {
    var onLidClosed: (() -> Void)?

    private var service: io_service_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notification: io_object_t = IO_OBJECT_NULL
    private var lastKnownClosed: Bool?

    deinit {
        if notification != IO_OBJECT_NULL {
            IOObjectRelease(notification)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        if service != IO_OBJECT_NULL {
            IOObjectRelease(service)
        }
    }

    func start() {
        guard service == IO_OBJECT_NULL, let matching = IOServiceMatching("IOPMrootDomain") else { return }
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard rootDomain != IO_OBJECT_NULL else { return }
        service = rootDomain

        // A lid that is already closed at launch must not fire the handler.
        lastKnownClosed = readClamshellClosed()

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(
            port,
            service,
            kIOGeneralInterest,
            { context, _, _, _ in
                guard let context else { return }
                let monitor = Unmanaged<ClamshellMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handleInterestNotification()
            },
            context,
            &notification
        )
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            notificationPort = nil
            return
        }

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    func readClamshellClosed() -> Bool? {
        guard service != IO_OBJECT_NULL else { return nil }
        return IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
    }

    /// Any external screen keeps the session usable with the lid shut, so the
    /// built-in display must not be put to sleep by hand.
    static func hasExternalDisplay() -> Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
    }

    private func handleInterestNotification() {
        let closed = readClamshellClosed()
        let wasClosed = lastKnownClosed
        lastKnownClosed = closed
        guard closed == true, wasClosed != true else { return }
        onLidClosed?()
    }
}
