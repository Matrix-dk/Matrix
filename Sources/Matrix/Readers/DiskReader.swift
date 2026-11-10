import Foundation
import IOKit

/// 容量走 statfs("/")，读写速率走 IOKit 里 IOBlockStorageDriver 的 Statistics 累计量。
final class DiskReader {

    private var previousRead: UInt64 = 0
    private var previousWrite: UInt64 = 0
    private var hasBaseline = false

    func sample(interval: Double) -> DiskSample {
        var sample = DiskSample()

        var fileSystem = statfs()
        if statfs("/", &fileSystem) == 0 {
            let blockSize = UInt64(fileSystem.f_bsize)
            sample.total = UInt64(fileSystem.f_blocks) * blockSize
            sample.free = UInt64(fileSystem.f_bavail) * blockSize
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
