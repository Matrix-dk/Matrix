import Foundation
import IOKit
import Darwin

/// 通过 IOKit 的 AppleSMC 用户客户端读传感器。
///
/// 这里没有用 Swift struct 去对 C 结构体内存布局（布局一旦对不上就是脏读），
/// 而是直接按 smc.h 里 SMCKeyData_t 的已知偏移拼 80 字节 buffer：
///
///   0  key(4, BE) | 4 vers | 12 pLimitData | 28 keyInfo{size,type} |
///   40 result | 41 status | 42 data8 | 44 data32 | 48 bytes[32]
///
/// 读一个 key 要两次调用：先 READ_KEYINFO 拿数据类型和长度，再 READ_BYTES 拿值。
///
/// **key 名各机型不一样**，所以这里不写死 TC0P 之类的单点方案，而是：
/// 1. 读 `#KEY` 拿到 key 总数；
/// 2. 用 GET_KEY_FROM_INDEX 逐个枚举出真实存在的 key；
/// 3. 试读每个 key 的值，按「首字母 + 数据类型 + 取值范围」归类（温度/电压/电流/功率/风扇）；
/// 4. 把归类结果按机型缓存到 UserDefaults，之后只读这份清单，不再全量扫。
final class SMCReader {

    private static let kernelIndexSMC: UInt32 = 2
    private static let commandReadBytes: UInt8 = 5
    private static let commandGetKeyFromIndex: UInt8 = 8
    private static let commandReadKeyInfo: UInt8 = 9
    private static let payloadSize = 80

    private var connection: io_connect_t = 0
    private var infoCache: [String: (size: UInt32, type: String)] = [:]

    private var temperatureKeys: [String] = []
    private var fanKeys: [String] = []
    private var voltageKeys: [String] = []
    private var currentKeys: [String] = []
    private var powerKeys: [String] = []
    private var discovered = false
    private var catalogueCount = 0

    private var hwModel: String = SMCReader.hardwareModel()

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        if IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS {
            self.connection = connection
            restoreCatalogue()
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

        if !discovered {
            discover()
        }
        sample.catalogueSize = catalogueCount
        guard !temperatureKeys.isEmpty || !fanKeys.isEmpty else { return sample }

        sample.temperatures = temperatureKeys.compactMap { key in
            guard let value = readDouble(key), value > 0, value < 130 else { return nil }
            return SensorReading(key: key, label: Self.friendlyName(key), value: value, category: .temperature)
        }

        sample.fans = fanKeys.compactMap { key in
            guard let value = readDouble(key), value >= 0, value < 20000 else { return nil }
            return SensorReading(key: key, label: Self.fanLabel(key), value: value, category: .fan)
        }

        sample.voltages = voltageKeys.compactMap { key in
            guard let value = readDouble(key), value > 0, value < 30 else { return nil }
            return SensorReading(key: key, label: Self.friendlyName(key), value: value, category: .voltage)
        }

        sample.currents = currentKeys.compactMap { key in
            guard let value = readDouble(key), abs(value) > 0.01, abs(value) < 100 else { return nil }
            return SensorReading(key: key, label: Self.friendlyName(key), value: value, category: .current)
        }

        sample.powers = powerKeys.compactMap { key in
            guard let value = readDouble(key), value > 0, value < 500 else { return nil }
            return SensorReading(key: key, label: Self.friendlyName(key), value: value, category: .power)
        }

        sample.cpuTemperature = Self.pickCPU(temperatures: sample.temperatures)
        sample.gpuTemperature = Self.pickGPU(temperatures: sample.temperatures)
        return sample
    }

    // MARK: - 枚举

    private func discover() {
        guard !discovered else { return }
        discovered = true
        guard isAvailable else { return }

        guard let countValue = readDouble("#KEY"), countValue > 0, countValue < 20000 else { return }
        let total = Int(countValue)
        catalogueCount = total

        for index in 0 ..< total {
            guard let key = keyFromIndex(index) else { continue }
            guard key != "#KEY" else { continue }
            guard let info = keyInfo(for: key), Self.isNumeric(type: info.type) else { continue }
            guard let value = readDouble(key) else { continue }

            switch Self.classify(key: key, value: value) {
            case .temperature: temperatureKeys.append(key)
            case .fan: fanKeys.append(key)
            case .voltage: voltageKeys.append(key)
            case .current: currentKeys.append(key)
            case .power: powerKeys.append(key)
            case .none: break
            }
        }

        // key 名有语义，按名字排序让界面稳定（不随枚举顺序跳）
        temperatureKeys.sort()
        fanKeys.sort()
        voltageKeys.sort()
        currentKeys.sort()
        powerKeys.sort()

        saveCatalogue()
    }

    private func keyFromIndex(_ index: Int) -> String? {
        var input = [UInt8](repeating: 0, count: Self.payloadSize)
        input[42] = Self.commandGetKeyFromIndex
        Self.writeBigEndian(&input, offset: 44, value: UInt32(index))

        guard let output = call(input) else { return nil }
        let key = Self.string(fromFourCharCode: Self.readBigEndian(output, offset: 0))
        return key.count == 4 ? key : nil
    }

    private static func classify(key: String, value: Double) -> SensorCategory? {
        // 风扇：F0Ac / F1Ac
        if key.count == 4, key.hasPrefix("F"), key.hasSuffix("Ac") {
            return value >= 0 && value < 20000 ? .fan : nil
        }
        guard let first = key.first else { return nil }
        switch first {
        case "T":
            return (value > 0 && value < 130) ? .temperature : nil
        case "V":
            return (value > 0.1 && value < 30) ? .voltage : nil
        case "I":
            return (abs(value) > 0.01 && abs(value) < 100) ? .current : nil
        case "P":
            return (value > 0.1 && value < 500) ? .power : nil
        default:
            return nil
        }
    }

    private static func isNumeric(type: String) -> Bool {
        switch type {
        case "flt ", "sp78", "fpe2", "ui8 ", "ui16", "ui32", "si8 ", "si16":
            return true
        default:
            return false
        }
    }

    // MARK: - 机型缓存

    private struct CachedCatalogue: Codable {
        var temperature: [String]
        var fan: [String]
        var voltage: [String]
        var current: [String]
        var power: [String]
        var total: Int
    }

    private var cacheKey: String { "smcCatalogue.v3.\(hwModel)" }

    private func restoreCatalogue() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(CachedCatalogue.self, from: data),
              !cached.temperature.isEmpty || !cached.fan.isEmpty else {
            return
        }
        temperatureKeys = cached.temperature
        fanKeys = cached.fan
        voltageKeys = cached.voltage
        currentKeys = cached.current
        powerKeys = cached.power
        catalogueCount = cached.total
        discovered = true
    }

    private func saveCatalogue() {
        let cached = CachedCatalogue(temperature: temperatureKeys,
                                     fan: fanKeys,
                                     voltage: voltageKeys,
                                     current: currentKeys,
                                     power: powerKeys,
                                     total: catalogueCount)
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
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
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(Self.readBigEndian(bytes, offset: 0))
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])))
        case "ui8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case "si8 ":
            guard bytes.count >= 1 else { return nil }
            return Double(Int8(bitPattern: bytes[0]))
        default:
            return nil
        }
    }

    // MARK: - 命名

    private static let knownNames: [String: String] = [
        "TC0P": "CPU 附近",
        "TC0D": "CPU 核心",
        "TC0E": "CPU",
        "TC0F": "CPU",
        "TC0H": "CPU 散热片",
        "TC0C": "CPU",
        "TCXC": "CPU 核心",
        "TCGC": "GPU 附近",
        "TG0P": "GPU",
        "TG0D": "GPU 核心",
        "Tp01": "性能核 1",
        "Tp05": "性能核 2",
        "Tp09": "能效核 1",
        "Tp0T": "能效核 2",
        "Tp0b": "CPU",
        "Tp0D": "CPU",
        "Tp0f": "CPU",
        "TB0T": "电池附近",
        "TB1T": "电池 1",
        "TB2T": "电池 2",
        "Ts0P": "掌托",
        "Ts0S": "掌托",
        "TA0P": "环境",
        "TH0P": "硬盘",
        "TN0P": "内存",
        "TW0P": "无线",
        "Tm0P": "内存"
    ]

    private static func friendlyName(_ key: String) -> String {
        if let known = knownNames[key] { return known }
        return key
    }

    private static func fanLabel(_ key: String) -> String {
        // F0Ac / F1Ac → 风扇 1 / 风扇 2
        if key.count >= 2, let index = Int(String(key.dropFirst().prefix(1))) {
            return "风扇 \(index + 1)"
        }
        return key
    }

    private static let cpuPriority = ["Tp01", "Tp05", "Tp09", "Tp0T", "TC0D", "TC0P", "TCXC", "TC0E", "TC0F"]
    private static let gpuPriority = ["Tg0P", "TG0D", "TCGC", "Tg0D"]

    private static func pickCPU(temperatures: [SensorReading]) -> Double? {
        for key in cpuPriority {
            if let match = temperatures.first(where: { $0.key == key }) { return match.value }
        }
        // 兜底：取最高的那个（通常就是负载最高的核心）
        return temperatures.map(\.value).max()
    }

    private static func pickGPU(temperatures: [SensorReading]) -> Double? {
        for key in gpuPriority {
            if let match = temperatures.first(where: { $0.key == key }) { return match.value }
        }
        return nil
    }

    // MARK: - 字节工具

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

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
