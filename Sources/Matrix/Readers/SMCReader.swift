import Foundation
import IOKit

/// 通过 IOKit 的 AppleSMC 用户客户端读 SMC key。
///
/// 这里没有用 Swift struct 去对 C 结构体内存布局（布局一旦对不上就是脏读），
/// 而是直接按 smc.h 里 SMCKeyData_t 的已知偏移拼 80 字节 buffer：
///
///   0  key(4, BE) | 4 vers | 12 pLimitData | 28 keyInfo{size,type} |
///   40 result | 41 status | 42 data8 | 44 data32 | 48 bytes[32]
///
/// 读一个 key 要两次调用：先 READ_KEYINFO 拿数据类型和长度，再 READ_BYTES 拿值。
final class SMCReader {

    private static let kernelIndexSMC: UInt32 = 2
    private static let commandReadBytes: UInt8 = 5
    private static let commandReadKeyInfo: UInt8 = 9
    private static let payloadSize = 80

    private var connection: io_connect_t = 0
    private var infoCache: [String: (size: UInt32, type: String)] = [:]

    /// 各机型温度 key 不一样：Intel 一般是 TC0P/TC0D，Apple Silicon 是 Tp0x 系列。
    private let temperatureKeys = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TCXC", "TC0H",
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0b", "Tp0f",
        "Tc0P", "Tc0c", "Tc0d", "Ts0P"
    ]

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        if IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS {
            self.connection = connection
        }
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    var isAvailable: Bool { connection != 0 }

    // MARK: - 对外

    func sample() -> SensorSample {
        var sample = SensorSample()
        sample.smcAvailable = isAvailable
        guard isAvailable else { return sample }

        for key in temperatureKeys {
            if let value = readDouble(key), value > 15, value < 125 {
                sample.cpuTemperature = value
                break
            }
        }

        if let count = readDouble("FNum") {
            let fanCount = max(0, min(Int(count), 4))
            for index in 0 ..< fanCount {
                if let rpm = readDouble("F\(index)Ac"), rpm >= 0, rpm < 20000 {
                    sample.fanRPMs.append(rpm)
                }
            }
        }
        return sample
    }

    // MARK: - SMC 调用

    private func readDouble(_ key: String) -> Double? {
        guard let info = keyInfo(for: key),
              let bytes = readBytes(key, info: info) else { return nil }
        return decode(bytes: bytes, type: info.type)
    }

    private func keyInfo(for key: String) -> (size: UInt32, type: String)? {
        if let cached = infoCache[key] { return cached }
        guard let code = Self.fourCharCode(key) else { return nil }

        var input = [UInt8](repeating: 0, count: Self.payloadSize)
        Self.writeBigEndian(&input, offset: 0, value: code)
        input[42] = Self.commandReadKeyInfo

        guard let output = call(input) else { return nil }
        let size = Self.readBigEndian(output, offset: 28)
        let type = Self.string(fromFourCharCode: Self.readBigEndian(output, offset: 32))
        guard size > 0, size <= 32, !type.isEmpty else { return nil }

        let info = (size: size, type: type)
        infoCache[key] = info
        return info
    }

    private func readBytes(_ key: String, info: (size: UInt32, type: String)) -> [UInt8]? {
        guard let code = Self.fourCharCode(key),
              let typeCode = Self.fourCharCode(info.type) else { return nil }

        var input = [UInt8](repeating: 0, count: Self.payloadSize)
        Self.writeBigEndian(&input, offset: 0, value: code)
        input[42] = Self.commandReadBytes
        Self.writeBigEndian(&input, offset: 28, value: info.size)
        Self.writeBigEndian(&input, offset: 32, value: typeCode)

        guard let output = call(input) else { return nil }
        let length = Int(info.size)
        guard output.count >= 48 + length else { return nil }
        return Array(output[48 ..< 48 + length])
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        guard connection != 0 else { return nil }
        var output = [UInt8](repeating: 0, count: Self.payloadSize)
        var outputSize = Self.payloadSize

        let result = input.withUnsafeBytes { inputRaw -> kern_return_t in
            output.withUnsafeMutableBytes { outputRaw -> kern_return_t in
                IOConnectCallStructMethod(connection,
                                          Self.kernelIndexSMC,
                                          inputRaw.baseAddress,
                                          Self.payloadSize,
                                          outputRaw.baseAddress,
                                          &outputSize)
            }
        }
        guard result == kIOReturnSuccess else { return nil }
        return output
    }

    // MARK: - 数值解码

    private func decode(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = Self.readBigEndian(bytes, offset: 0)
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        default:
            return nil
        }
    }

    // MARK: - 字节工具

    private static func fourCharCode(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func string(fromFourCharCode code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private static func writeBigEndian(_ buffer: inout [UInt8], offset: Int, value: UInt32) {
        buffer[offset] = UInt8((value >> 24) & 0xFF)
        buffer[offset + 1] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(value & 0xFF)
    }

    private static func readBigEndian(_ buffer: [UInt8], offset: Int) -> UInt32 {
        (UInt32(buffer[offset]) << 24)
            | (UInt32(buffer[offset + 1]) << 16)
            | (UInt32(buffer[offset + 2]) << 8)
            | UInt32(buffer[offset + 3])
    }
}
