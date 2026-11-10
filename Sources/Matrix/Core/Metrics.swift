import Foundation

// MARK: - 采样数据结构

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

struct MemorySample {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0                   // App 内存（internal - purgeable）
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0                // 文件缓存
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0

    var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    var free: UInt64 { total > used ? total - used : 0 }
}

struct NetworkSample {
    var downBytesPerSec: Double = 0
    var upBytesPerSec: Double = 0
    var totalDown: UInt64 = 0
    var totalUp: UInt64 = 0
    var interfaceName: String = ""
    var ipAddress: String = ""
    var hasInterface: Bool = false
}

struct DiskSample {
    var total: UInt64 = 0
    var free: UInt64 = 0
    var readBytesPerSec: Double = 0
    var writeBytesPerSec: Double = 0

    var used: UInt64 { total > free ? total - free : 0 }
    var usage: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

struct BatterySample {
    var percent: Double = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var timeRemainingMinutes: Int? = nil
    var cycleCount: Int? = nil
    var healthPercent: Double? = nil
    var temperatureCelsius: Double? = nil
}

struct ProcessSample: Identifiable, Hashable {
    var id: Int32 { pid }
    var pid: Int32
    var name: String
    var cpu: Double          // 百分比，如 12.5
    var memory: UInt64       // bytes
}

struct SensorSample {
    var cpuTemperature: Double? = nil
    var fanRPMs: [Double] = []
    var smcAvailable: Bool = false
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
}
