import Foundation
import IOKit

protocol SMCTransport: AnyObject {
    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32, type: String)
    func writeKey(_ key: String, bytes: [UInt8]) -> Bool
    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)?
}

// AppleSMC userspace structure/command interface.
// Adapted from MIT-licensed interoperability research; see THIRD_PARTY_NOTICES.md.

enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case getKeyFromIndex = 8
    case readKeyInfo = 9
}

private let kSMCHandleIndex: UInt32 = 2

struct SMCParamStruct {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
    )
}

public final class SMCConnection {
    private let connection: io_connect_t

    public init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        ) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            return nil
        }
        self.connection = conn
    }

    deinit {
        IOServiceClose(connection)
    }

    public func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32, type: String) {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return (false, [], 0, "")
        }

        let dataSize = output.keyInfo.dataSize
        let dataType = fourCharString(output.keyInfo.dataType)
        guard dataSize > 0 && dataSize <= 32 else {
            return (false, [], dataSize, dataType)
        }

        input.keyInfo.dataSize = dataSize
        input.data8 = SMCCommand.readBytes.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess, output.result == 0 else {
            return (false, [], dataSize, dataType)
        }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(dataSize))) }
        return (true, bytes, dataSize, dataType)
    }

    public func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        guard bytes.count <= 32 else { return false }

        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue

        guard callSMC(&input, &output) == kIOReturnSuccess else { return false }
        let size = Int(output.keyInfo.dataSize)
        guard size > 0, size <= 32, bytes.count <= size else { return false }

        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.bytes = arrayToTuple(bytes)

        guard callSMC(&input, &output) == kIOReturnSuccess else { return false }
        return output.result == 0
    }

    public func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess else { return nil }
        return (output.keyInfo.dataSize, fourCharString(output.keyInfo.dataType))
    }

    private func callSMC(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(
            connection,
            kSMCHandleIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
    }

    private func fourCharCode(_ key: String) -> UInt32 {
        precondition(key.utf8.count == 4, "SMC keys must be exactly four bytes")
        return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func arrayToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes {
        var padded = array + Array(repeating: UInt8(0), count: max(0, 32 - array.count))
        if padded.count > 32 { padded = Array(padded.prefix(32)) }
        return (
            padded[0], padded[1], padded[2], padded[3], padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11], padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19], padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27], padded[28], padded[29], padded[30], padded[31]
        )
    }
}

extension SMCConnection: SMCTransport {}
