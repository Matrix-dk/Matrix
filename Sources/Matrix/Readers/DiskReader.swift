import Foundation
import IOKit

/// 容量走挂载卷枚举 + statfs 兜底，读写速率走 IOKit 里 IOBlockStorageDriver 的 Statistics 累计量。
/// 根卷容量单独保留一份（状态栏只显示它），面板里再列出所有本地卷。
final class DiskReader {

    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var hasBaseline = false

    func sample(interval: Double) -> DiskSample {
        var sample = DiskSample()

        let volumes = Self.mountedVolumes()
        sample.volumes = volumes

        // 根卷：优先从枚举里找，找不到就 statfs
        if let root = volumes.first(where: { $0.mountPoint == "/" }) {
            sample.total = root.total
            sample.free = root.free
        } else {
            var fileSystem = statfs()
            if statfs("/", &fileSystem) == 0 {
                let blockSize = UInt64(fileSystem.f_bsize)
                sample.total = UInt64(fileSystem.f_blocks) * blockSize
                sample.free = UInt64(fileSystem.f_bavail) * blockSize
            }
        }

        let totals = Self.ioTotals()
        if hasBaseline, totals.read >= previousRead, totals.write >= previousWrite {
            let divisor = max(interval, 0.2)
            sample.readBytesPerSec = Double(totals.read - previousRead) / divisor
            sample.writeBytesPerSec = Double(totals.write - previousWrite) / divisor
        }
        previousRead = totals.read
        previousWrite = totals.write
        hasBaseline = true

        return sample
    }

    // MARK: - 卷

    private static func mountedVolumes() -> [VolumeSample] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: []) else {
            return []
        }

        var result: [VolumeSample] = []
        var seen = Set<String>()

        for url in urls {
            let path = url.path
            // 跳过 APFS 容器内部的合成卷（Data / VM / Preboot 等），它们不是用户能用的卷
            if path.hasPrefix("/System/Volumes/") { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsLocal == true else { continue }
            if values.volumeIsBrowsable == false { continue }

            let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
            guard total > 0 else { continue }
            // ForImportantUsage 更接近 Finder 里显示的可用空间
            let freeRaw = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            let free = UInt64(max(0, freeRaw))

            var volume = VolumeSample()
            volume.name = values.volumeName ?? url.lastPathComponent
            volume.mountPoint = path
            volume.total = total
            volume.free = min(free, total)
            volume.isInternal = values.volumeIsInternal ?? false

            guard !seen.contains(volume.name + "|\(total)") else { continue }
            seen.insert(volume.name + "|\(total)")
            result.append(volume)
        }

        // 内部卷优先，大的排前面
        result.sort { lhs, rhs in
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.total > rhs.total
        }
        return result
    }

    // MARK: - IO

    /// 汇总所有块设备驱动的累计读写字节
    private static func ioTotals() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0

        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return (read, write)
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(service,
                                                                 "Statistics" as CFString,
                                                                 kCFAllocatorDefault,
                                                                 0)?.takeRetainedValue(),
                  let statistics = property as? [String: Any] else { continue }

            if let value = statistics["Bytes (Read)"] as? NSNumber {
                read += value.uint64Value
            }
            if let value = statistics["Bytes (Write)"] as? NSNumber {
                write += value.uint64Value
            }
        }
        return (read, write)
    }
}
