import Foundation
import Darwin

/// CPU 占用来自 mach host_processor_info。内核给的是每个核心的累计 tick，
/// 必须自己保存上一次的值算差值，才能得到瞬时占用。
final class CPUReader {

    private var previousTicks: [UInt32] = []

    func sample() -> CPUSample? {
        var processorCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(),
                                        PROCESSOR_CPU_LOAD_INFO,
                                        &processorCount,
                                        &infoPointer,
                                        &infoCount)
        guard result == KERN_SUCCESS, let info = infoPointer else { return nil }

        // mach 出来的内存要还回去，否则每秒泄漏一点
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            _ = vm_deallocate(mach_task_self_,
                              vm_address_t(UInt(bitPattern: UnsafeRawPointer(info))),
                              size)
        }

        let coreCount = Int(processorCount)
        let stateCount = Int(CPU_STATE_MAX)
        guard coreCount > 0, Int(infoCount) >= coreCount * stateCount else { return nil }

        var current = [UInt32](repeating: 0, count: coreCount * stateCount)
        for index in 0 ..< (coreCount * stateCount) {
            // tick 是 32 位无符号，长时间运行后顶位可能为 1，用 bitPattern 转换避免变成负数
            current[index] = UInt32(bitPattern: info[index])
        }

        var perCore = [Double](repeating: 0, count: coreCount)
        var userDelta = 0.0
        var systemDelta = 0.0
        var allDelta = 0.0

        if previousTicks.count == current.count {
            for core in 0 ..< coreCount {
                let base = core * stateCount
                // 用 &- 做回绕减法：计数器每秒增量远小于 2^32，结果一定准确
                let user = current[base] &- previousTicks[base]
                let system = current[base + 1] &- previousTicks[base + 1]
                let idle = current[base + 2] &- previousTicks[base + 2]
                let nice = current[base + 3] &- previousTicks[base + 3]

                let busy = Double(user) + Double(system) + Double(nice)
                let total = busy + Double(idle)
                perCore[core] = total > 0 ? min(1, busy / total) : 0

                userDelta += Double(user) + Double(nice)
                systemDelta += Double(system)
                allDelta += total
            }
        }
        previousTicks = current

        var sample = CPUSample()
        sample.perCore = perCore
        if allDelta > 0 {
            sample.usage = min(1, (userDelta + systemDelta) / allDelta)
            sample.user = userDelta / allDelta
            sample.system = systemDelta / allDelta
        } else {
            sample.usage = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        }

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            sample.loadOne = loads[0]
            sample.loadFive = loads[1]
            sample.loadFifteen = loads[2]
        }
        sample.uptime = ProcessInfo.processInfo.systemUptime
        return sample
    }
}
