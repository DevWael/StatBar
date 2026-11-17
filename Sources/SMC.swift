import Foundation
import IOKit

/// Reads keys from the System Management Controller (temperatures, fans, power).
final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyInfoData] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func name(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> SMCKeyInfoData? {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo
        guard let out = call(&input) else { return nil }
        infoCache[key] = out.keyInfo
        return out.keyInfo
    }

    /// Raw bytes and type code for a key, or nil if the key doesn't exist.
    func read(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
        guard let keyInfo = info(key) else { return nil }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = 5 // kSMCReadKey
        guard let out = call(&input) else { return nil }
        let size = min(Int(keyInfo.dataSize), 32)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return (keyInfo.dataType, bytes)
    }

    func value(_ key: String) -> Double? { value(SMC.code(key)) }

    func value(_ key: UInt32) -> Double? {
        guard let (type, b) = read(key), !b.isEmpty else { return nil }
        switch SMC.name(type) {
        case "flt " where b.count >= 4:
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "ui8 ":
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "sp78" where b.count >= 2:
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        case "fpe2" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        default:
            return nil
        }
    }

    /// Every key the SMC exposes. Slow (one call per key), so run it once.
    func allKeys() -> [UInt32] {
        guard let count = value("#KEY") else { return [] }
        var keys: [UInt32] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<UInt32(count) {
            var input = SMCParamStruct()
            input.data8 = 8 // kSMCGetKeyFromIndex
            input.data32 = index
            if let out = call(&input) { keys.append(out.key) }
        }
        return keys
    }
}
