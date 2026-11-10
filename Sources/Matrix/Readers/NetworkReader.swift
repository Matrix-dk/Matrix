import Foundation
import Darwin

/// 网络流量走 getifaddrs 读 AF_LINK 上的 if_data 计数器。
/// if_data 的 ifi_ibytes / ifi_obytes 是 32 位，超过 4GB 会回绕，
/// 所以差值一律用 UInt32 的回绕减法（&-）算，秒级采样下不会丢量。
final class NetworkReader {

    private var previousCounters: [String: (down: UInt32, up: UInt32)] = [:]
    private var accumulatedDown: UInt64 = 0
    private var accumulatedUp: UInt64 = 0

    func sample(interval: Double) -> NetworkSample {
        var sample = NetworkSample()
        var addresses: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return sample
        }
        defer { freeifaddrs(addresses) }

        var currentCounters: [String: (down: UInt32, up: UInt32)] = [:]
        var ipAddress = ""
        var primaryName = ""

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let entry = interface.pointee
            let flags = Int32(bitPattern: entry.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let name = String(cString: entry.ifa_name)

            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), isUp, !isLoopback {
                if let raw = entry.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    currentCounters[name] = (data.ifi_ibytes, data.ifi_obytes)
                }
            }

            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               isUp, !isLoopback, ipAddress.isEmpty, name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    ipAddress = String(cString: host)
                    primaryName = name
                }
            }

            cursor = entry.ifa_next
        }

        var downDelta = 0.0
        var upDelta = 0.0
        for (name, counters) in currentCounters {
            if let previous = previousCounters[name] {
                downDelta += Double(counters.down &- previous.down)
                upDelta += Double(counters.up &- previous.up)
            }
        }
        previousCounters = currentCounters

        // 累计量自己加，不用计数器原值（原值会回绕）
        accumulatedDown &+= UInt64(downDelta)
        accumulatedUp &+= UInt64(upDelta)

        let divisor = max(interval, 0.2)
        sample.downBytesPerSec = downDelta / divisor
        sample.upBytesPerSec = upDelta / divisor
        sample.totalDown = accumulatedDown
        sample.totalUp = accumulatedUp
        sample.ipAddress = ipAddress
        sample.interfaceName = primaryName
        sample.hasInterface = !currentCounters.isEmpty
        return sample
    }
}
