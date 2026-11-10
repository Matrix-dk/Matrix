import Foundation

// MARK: - CPU

struct CPUSample {
    var usage: Double = 0                 // 0...1 总体占用
    var perCore: [Double] = []            // 每个核心 0...1
    var user: Double = 0
    var system: Double = 0
    var loadOne: Double = 0
    var loadFive: Double = 0
    var loadFifteen: Double = 0
    var uptime: TimeInterval = 0
    var coreCount: Int { perCore.count }
}

// MARK: - 内存

enum MemoryPressure: Int, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(level: Int32) {
        if level >= 4 { self = .critical }
        else if level >= 2 { self = .warning }
        else { self = .normal }
    }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "紧张"
        }
    }

    static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MemorySample {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0                   // App 内存（internal - purgeable）
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0                // 文件缓存
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure: MemoryPressure = .normal

    var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var free: UInt64 { total > used ? total - used : 0 }
    var swapUsage: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
}

// MARK: - GPU

struct GPUSample {
    var available: Bool = false
    var name: String = ""
    var utilization: Double = 0           // 0...1 Device Utilization
    var renderUtilization: Double = 0
    var tilerUtilization: Double = 0
    var usedMemory: UInt64 = 0
    var allocatedMemory: UInt64 = 0
    var coreCount: Int = 0
}

// MARK: - 网络

struct InterfaceSample: Identifiable, Hashable {
    var id: String { name }
    var name: String = ""
    var displayName: String = ""
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var ipAddress: String = ""
    var isPrimary: Bool = false
    var isWiFi: Bool = false
}

struct WiFiSample {
    var available: Bool = false
    var powered: Bool = false
    var ssid: String? = nil
    var rssi: Int? = nil                  // dBm，-30 极好，-80 很差
    var noise: Int? = nil
    var channel: String? = nil
    var txRateMbps: Double? = nil
    var phyMode: String? = nil
    var security: String? = nil

    /// 信号强度换算成 0...1，用于画条
    var signalFraction: Double {
        guard let rssi else { return 0 }
        return min(1, max(0, (Double(rssi) + 100) / 60))
    }

    var signalBars: Int {
        guard rssi != nil else { return 0 }
        return min(4, max(1, Int((signalFraction * 4).rounded(.up))))
    }
}

struct NetworkSample {
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var interfaceName: String = ""
    var ipAddress: String = ""
    var hasInterface: Bool = false
    var interfaces: [InterfaceSample] = []
}

// MARK: - 磁盘

struct VolumeSample: Identifiable, Hashable {
    var id: String { mountPoint }
    var name: String = ""
    var mountPoint: String = ""
    var total: UInt64 = 0
    var free: UInt64 = 0
    var isInternal: Bool = false

    var used: UInt64 { total > free ? total - free : 0 }
    var usage: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct DiskSample {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0
    var volumes: [VolumeSample] = []

    var used: UInt64 { total > free ? total - free : 0 }
    var usage: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

// MARK: - 电池

struct BatterySample {
    var percent: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemainingMinutes: Int? = nil
    var cycleCount: Int? = nil
    var healthPercent: Double? = nil
    var temperatureCelsius: Double? = nil
    var amperageMilliAmps: Double? = nil
    var voltageMilliVolts: Double? = nil

    /// 放电为负、充电为正（瓦特）
    var powerWatts: Double? {
        guard let amperage = amperageMilliAmps, let voltage = voltageMilliVolts else { return nil }
        return amperage / 1000.0 * voltage / 1000.0
    }
}

// MARK: - 进程

struct ProcessSample: Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: Double          // 百分比，如 12.5
    var memory: UInt64       // bytes
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu
    case memory

    var id: String { rawValue }
    var title: String { self == .cpu ? "按 CPU" : "按内存" }
}

// MARK: - 传感器

enum SensorCategory: String, Codable {
    case temperature
    case fan
    case voltage
    case current
    case power
}

struct SensorReading: Identifiable, Hashable {
    var id: String { key }
    var key: String = ""          // SMC key，如 Tp01
    var label: String = ""
    var value: Double = 0
    var category: SensorCategory = .temperature

    var formatted: String {
        switch category {
        case .temperature: return String(format: "%.1f°C", value)
        case .fan: return String(format: "%.0f RPM", value)
        case .voltage: return String(format: "%.3f V", value)
        case .current: return String(format: "%.2f A", value)
        case .power: return String(format: "%.2f W", value)
        }
    }
}

struct SensorSample {
    var cpuTemperature: Double? = nil
    var gpuTemperature: Double? = nil
    var temperatures: [SensorReading] = []
    var fans: [SensorReading] = []
    var voltages: [SensorReading] = []
    var currents: [SensorReading] = []
    var powers: [SensorReading] = []
    var smcAvailable: Bool = false
    var catalogueSize: Int = 0

    var fanRPMs: [Double] { fans.map(\.value) }
    var averageTemperature: Double? {
        guard !temperatures.isEmpty else { return cpuTemperature }
        return temperatures.map(\.value).reduce(0, +) / Double(temperatures.count)
    }
}

// MARK: - 历史曲线（固定容量环形缓冲）

struct History {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 120) {
        self.capacity = capacity
    }

    mutating func push(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    var latest: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }

    func suffix(_ count: Int) -> [Double] {
        guard values.count > count else { return values }
        return Array(values.suffix(count))
    }
}

// MARK: - 时间范围

enum TimeRange: String, CaseIterable, Identifiable {
    case hour
    case day
    case week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1 小时"
        case .day: return "24 小时"
        case .week: return "7 天"
        }
    }

    var shortTitle: String {
        switch self {
        case .hour: return "1h"
        case .day: return "24h"
        case .week: return "7d"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86400
        case .week: return 604800
        }
    }

    /// 绘图的桶数量，太小会糊、太大浪费
    var bucketCount: Int {
        switch self {
        case .hour: return 180
        case .day: return 240
        case .week: return 240
        }
    }
}

// MARK: - 历史指标

enum HistoryMetric: String, CaseIterable {
    case cpu
    case memory
    case gpu
    case netDown
    case netUp
    case diskRead
    case diskWrite
    case temperature
    case battery

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .gpu: return "GPU"
        case .netDown: return "下行"
        case .netUp: return "上行"
        case .diskRead: return "读取"
        case .diskWrite: return "写入"
        case .temperature: return "温度"
        case .battery: return "电量"
        }
    }

    /// 归一化上限，nil 表示按数据自身峰值缩放
    var fixedCeiling: Double? {
        switch self {
        case .cpu, .memory, .gpu, .battery: return 1
        default: return nil
        }
    }
}

// MARK: - 格式化

enum Format {
    /// 1_234_567 → "1.2 MB"
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(0, value)
        var index = 0
        while v >= 1024 && index < units.count - 1 {
            v /= 1024
            index += 1
        }
        if index == 0 { return String(format: "%.0f %@", v, units[index]) }
        return String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[index])
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    /// 传输速率
    static func rate(_ value: Double) -> String {
        if value < 1 { return "0 B/s" }
        return bytes(value) + "/s"
    }

    /// 菜单栏用的紧凑速率：12.3M / 880K
    static func compactRate(_ value: Double) -> String {
        if value < 1024 { return "0" }
        let units = ["K", "M", "G", "T"]
        var v = value / 1024
        var index = 0
        while v >= 1024 && index < units.count - 1 {
            v /= 1024
            index += 1
        }
        return String(format: v >= 100 ? "%.0f%@" : "%.1f%@", v, units[index])
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }

    static func percent(_ fraction: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f%%", max(0, min(1, fraction)) * 100)
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes)分"
    }

    static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func hourMark(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func weekdayMark(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    static func detailDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
