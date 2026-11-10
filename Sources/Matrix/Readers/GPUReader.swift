import Foundation
import IOKit

/// GPU 占用从 IORegistry 的 `IOAccelerator` 节点读 `PerformanceStatistics`。
/// Apple Silicon 上是 AGXAccelerator、Intel 上是 IntelAccelerator，键名一致，
/// 所以一套代码能吃两种机器。取不到就返回 `available = false`，界面整块隐藏。
final class GPUReader {

    func sample() -> GPUSample {
        var result = GPUSample()

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let raw = IORegistryEntryCreateCFProperty(service,
                                                            "PerformanceStatistics" as CFString,
                                                            kCFAllocatorDefault,
                                                            0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }

            var candidate = GPUSample()
            candidate.available = true
            candidate.name = Self.modelName(for: service)
            candidate.utilization = Self.fraction(stats["Device Utilization %"])
            candidate.renderUtilization = Self.fraction(stats["Renderer Utilization %"])
            candidate.tilerUtilization = Self.fraction(stats["Tiler Utilization %"])
            candidate.usedMemory = Self.byteValue(stats["vramUsedBytes"])
                ?? Self.byteValue(stats["In use system memory"])
                ?? 0
            candidate.allocatedMemory = Self.byteValue(stats["vramAllocatedBytes"])
                ?? Self.byteValue(stats["Alloc system memory"])
                ?? 0
            candidate.coreCount = Int(Self.byteValue(stats["gpu-core-count"]) ?? 0)

            // 多 GPU 时取占用最高的那个（外接显卡/双显卡机器）
            if !result.available || candidate.utilization > result.utilization {
                result = candidate
            }
        }
        return result
    }

    private static func modelName(for service: io_service_t) -> String {
        if let raw = IORegistryEntryCreateCFProperty(service,
                                                     "model" as CFString,
                                                     kCFAllocatorDefault,
                                                     0)?.takeRetainedValue() as? String {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let raw = IORegistryEntryCreateCFProperty(service,
                                                     "IOClass" as CFString,
                                                     kCFAllocatorDefault,
                                                     0)?.takeRetainedValue() as? String {
            return raw
        }
        return "GPU"
    }

    /// 有的机型给 0~100，有的给 0~1，统一成 0~1
    private static func fraction(_ value: Any?) -> Double {
        guard let number = value as? NSNumber else { return 0 }
        let raw = number.doubleValue
        let normalized = raw > 1 ? raw / 100 : raw
        return min(1, max(0, normalized))
    }

    private static func byteValue(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw > 0 else { return 0 }
        return UInt64(raw)
    }
}
