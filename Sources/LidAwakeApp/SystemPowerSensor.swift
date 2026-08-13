import Foundation
import IOKit

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPowerLimits {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpu: UInt32 = 0
    var gpu: UInt32 = 0
    var memory: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var attributes: UInt8 = 0
}

private struct SMCKeyData {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    var key: UInt32 = 0
    var version = SMCVersion()
    var powerLimits = SMCPowerLimits()
    var keyInfo = SMCKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}

final class SystemPowerSensor {
    private static let readBytesCommand: UInt8 = 5
    private static let readKeyInfoCommand: UInt8 = 9
    private static let kernelSelector: UInt32 = 2
    private static let floatDataType = fourCharacterCode("flt ")
    private static let systemTotalKey = fourCharacterCode("PSTR")
    private static let externalInputKey = fourCharacterCode("PDTR")
    private static let batteryRailKey = fourCharacterCode("PPBR")

    private let connection: io_connect_t
    private var keyInfoByKey: [UInt32: SMCKeyInfo] = [:]

    init?() {
        guard let matching = IOServiceMatching("AppleSMC") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        var matchingService: io_object_t = IO_OBJECT_NULL
        while service != IO_OBJECT_NULL {
            var name = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(service, &name) == KERN_SUCCESS,
               String(cString: name) == "AppleSMCKeysEndpoint" {
                matchingService = service
                break
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        guard matchingService != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(matchingService) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(matchingService, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
        self.connection = connection
    }

    deinit {
        IOServiceClose(connection)
    }

    func readSystemWatts() -> Double? {
        readWatts(key: Self.systemTotalKey)
    }

    func readExternalInputWatts() -> Double? {
        readWatts(key: Self.externalInputKey)
    }

    func readBatteryDischargeWatts() -> Double? {
        readWatts(key: Self.batteryRailKey)
    }

    private func readWatts(key: UInt32) -> Double? {
        let info: SMCKeyInfo
        if let keyInfo = keyInfoByKey[key] {
            info = keyInfo
        } else {
            var request = SMCKeyData()
            request.key = key
            request.command = Self.readKeyInfoCommand
            guard let response = call(request),
                  response.result == 0,
                  response.keyInfo.dataSize == 4,
                  response.keyInfo.dataType == Self.floatDataType else {
                return nil
            }
            info = response.keyInfo
            keyInfoByKey[key] = info
        }

        var request = SMCKeyData()
        request.key = key
        request.keyInfo = info
        request.command = Self.readBytesCommand
        guard let response = call(request), response.result == 0 else { return nil }

        let value = withUnsafeBytes(of: response.bytes) { bytes in
            bytes.loadUnaligned(as: Float.self)
        }
        guard value.isFinite else { return nil }
        return Double(value)
    }

    private func call(_ request: SMCKeyData) -> SMCKeyData? {
        var request = request
        var response = SMCKeyData()
        var responseSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &request) { requestPointer in
            withUnsafeMutablePointer(to: &response) { responsePointer in
                IOConnectCallStructMethod(
                    connection,
                    Self.kernelSelector,
                    requestPointer,
                    MemoryLayout<SMCKeyData>.stride,
                    responsePointer,
                    &responseSize
                )
            }
        }
        return result == KERN_SUCCESS ? response : nil
    }

    private static func fourCharacterCode(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
