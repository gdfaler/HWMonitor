import Foundation
import IOKit

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

/// Клиент AppleSMC: температуры, мощности и вентиляторы читаются без root.
final class SMC {
    /// Повторяет SMCKeyData_t из ядра: ровно 80 байт.
    private struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 { case readBytes = 5, readIndex = 8, readKeyInfo = 9 }

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    init?() {
        guard MemoryLayout<KeyData>.size == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.size
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.size, &output, &size)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = infoCache[key] { return cached }
        var input = KeyData()
        input.key = key
        input.data8 = Command.readKeyInfo.rawValue
        guard let out = call(&input) else { return nil }
        let info = (out.keyInfo.dataSize, out.keyInfo.dataType)
        infoCache[key] = info
        return info
    }

    func type(of key: String) -> String? {
        keyInfo(fourCC(key)).map { fourCCString($0.type) }
    }

    func read(_ key: String) -> Double? { read(fourCC(key)) }

    func read(_ key: UInt32) -> Double? {
        guard let info = keyInfo(key), info.size > 0, info.size <= 32 else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue
        guard let out = call(&input) else { return nil }
        return withUnsafeBytes(of: out.bytes) { raw -> Double? in
            switch fourCCString(info.type) {
            case "flt ": return info.size == 4 ? Double(raw.loadUnaligned(as: Float32.self)) : nil
            case "ui8 ": return Double(raw[0])
            case "ui16": return Double(UInt16(raw[0]) << 8 | UInt16(raw[1]))
            case "ui32": return Double(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
            case "sp78": return Double(Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1]))) / 256
            case "fpe2": return Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) / 4
            default: return nil
            }
        }
    }

    /// Все ключи, которые знает SMC этой машины (несколько тысяч — вызывать один раз).
    func allKeys() -> [String] {
        guard let count = read("#KEY") else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<UInt32(count) {
            var input = KeyData()
            input.data8 = Command.readIndex.rawValue
            input.data32 = index
            if let out = call(&input) { keys.append(fourCCString(out.key)) }
        }
        return keys
    }
}
