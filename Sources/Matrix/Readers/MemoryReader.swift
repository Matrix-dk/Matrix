import Foundation
import Darwin

/// 内存统计取 host_statistics64 的 vm_statistics64，
/// 口径尽量贴近「活动监视器」：已用 = App 内存 + 联动内存 + 已压缩内存。
final class MemoryReader {

    private var pageSize: UInt64 = 4096
    private var previousPageIns: UInt64 = 0
    private var previousPageOuts: UInt64 = 0
    private var hasPageBaseline = false

    init() {
        var size: vm_size_t = 0
        if host_page_size(mach_host_self(), &size) == KERN_SUCCESS {
            pageSize = UInt64(size)
        }
    }

    func sample(interval: Double) -> MemorySample? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &statistics) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Double(pageSize)
        var sample = MemorySample()
        sample.total = ProcessInfo.processInfo.physicalMemory

        let inactive = Double(statistics.inactive_count) * page
        let wired = Double(statistics.wire_count) * page
        let compressed = Double(statistics.compressor_page_count) * page
        let purgeable = Double(statistics.purgeable_count) * page
        let external = Double(statistics.external_page_count) * page
        let internalPages = Double(statistics.internal_page_count) * page

        let appMemory = max(0, internalPages - purgeable)
        sample.app = UInt64(appMemory)
        sample.wired = UInt64(wired)
        sample.compressed = UInt64(compressed)
        sample.cached = UInt64(external + max(0, inactive))
        sample.used = UInt64(appMemory + wired + compressed)

        // 用一点保底，避免超过物理内存导致百分比 >100%
        if sample.used > sample.total {
            sample.used = sample.total
        }

        if let swap = Self.swapUsage() {
            sample.swapTotal = swap.total
            sample.swapUsed = swap.used
        }

        sample.pressure = Self.pressureLevel()

        // 页面换入/换出：vm_statistics64 里这两个是 64 位累计值，差值即本拍活动
        sample.pageIns = statistics.pageins
        sample.pageOuts = statistics.pageouts
        if hasPageBaseline,
           statistics.pageins >= previousPageIns,
           statistics.pageouts >= previousPageOuts {
            let divisor = max(interval, 0.2)
            sample.pageInRate = Double(statistics.pageins - previousPageIns) / divisor
            sample.pageOutRate = Double(statistics.pageouts - previousPageOuts) / divisor
        }
        previousPageIns = statistics.pageins
        previousPageOuts = statistics.pageouts
        hasPageBaseline = true

        return sample
    }

    /// 内核自己算好的内存压力等级：1 正常 / 2 偏高 / 4 紧张。
    /// 比拿「已用百分比」去猜准得多，和活动监视器的判断口径一致。
    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressure(level: level)
    }

    private static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let result = sysctl(&mib, u_int(mib.count), &usage, &size, nil, 0)
        guard result == 0 else { return nil }
        return (usage.xsu_total, usage.xsu_used)
    }
}
