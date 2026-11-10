import Foundation
import Darwin
import SystemConfiguration

/// 网络流量走 getifaddrs 读 AF_LINK 上的 if_data 计数器。
/// if_data 的 ifi_ibytes / ifi_obytes 是 32 位，超过 4GB 会回绕，
/// 所以差值一律用 UInt32 的回绕减法（&-）算，秒级采样下不会丢量。
///
/// 现在按接口分别统计（不是汇总），并把「默认路由接口」标出来，
/// 这样接 VPN / 外接网卡的时候能看清是哪条线在跑。
final class NetworkReader {

    private var previous: [String: (down: UInt32, up: UInt32)] = [:]
    private var accumulated: [String: (down: UInt64, up: UInt64)] = [:]
    private lazy var dynamicStore: SCDynamicStore? = SCDynamicStoreCreate(nil,
                                                                         "io.github.matrix.net" as CFString,
                                                                         nil,
                                                                         nil)

    func sample(interval: Double, wifiInterface: String? = nil) -> NetworkSample {
        var sample = NetworkSample()
        var addresses: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return sample
        }
        defer { freeifaddrs(addresses) }

        let primaryName = primaryInterfaceName()

        var counters: [String: (down: UInt32, up: UInt32)] = [:]
        var ips: [String: String] = [:]

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            let entry = interface.pointee
            let flags = Int32(bitPattern: entry.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let name = String(cString: entry.ifa_name)

            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               isUp, !isLoopback, Self.isPhysicalOrTunnel(name) {
                if let raw = entry.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    counters[name] = (data.ifi_ibytes, data.ifi_obytes)
                }
            }

            if let address = entry.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               isUp, !isLoopback {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    ips[name] = String(cString: host)
                }
            }

            cursor = entry.ifa_next
        }

        let divisor = max(interval, 0.2)
        var interfaces: [InterfaceSample] = []

        for (name, current) in counters {
            var item = InterfaceSample()
            item.name = name
            item.ipAddress = ips[name] ?? ""
            item.isPrimary = (name == primaryName)
            item.isWiFi = (name == wifiInterface)
            item.displayName = Self.displayName(for: name, isWiFi: item.isWiFi)

            if let old = previous[name] {
                let downDelta = Double(current.down &- old.down)
                let upDelta = Double(current.up &- old.up)
                item.downBytesPerSec = downDelta / divisor
                item.upBytesPerSec = upDelta / divisor

                var total = accumulated[name] ?? (0, 0)
                total.down &+= UInt64(downDelta)
                total.up &+= UInt64(upDelta)
                accumulated[name] = total
            }

            let total = accumulated[name] ?? (0, 0)
            item.totalDown = total.down
            item.totalUp = total.up
            interfaces.append(item)
        }
        previous = counters

        // 主接口排最前，其余按当前流量降序，静止的排后面
        interfaces.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            let lhsRate = lhs.downBytesPerSec + lhs.upBytesPerSec
            let rhsRate = rhs.downBytesPerSec + rhs.upBytesPerSec
            if lhsRate != rhsRate { return lhsRate > rhsRate }
            return lhs.name < rhs.name
        }

        sample.interfaces = interfaces
        sample.hasInterface = !interfaces.isEmpty

        if let primary = interfaces.first(where: { $0.isPrimary }) ?? interfaces.first {
            sample.interfaceName = primary.name
            sample.ipAddress = primary.ipAddress
            sample.downBytesPerSec = interfaces.reduce(0) { $0 + $1.downBytesPerSec }
            sample.upBytesPerSec = interfaces.reduce(0) { $0 + $1.upBytesPerSec }
            sample.totalDown = interfaces.reduce(0) { $0 + $1.totalDown }
            sample.totalUp = interfaces.reduce(0) { $0 + $1.totalUp }
        }
        return sample
    }

    // MARK: - 辅助

    private func primaryInterfaceName() -> String? {
        guard let store = dynamicStore,
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return value["PrimaryInterface"] as? String
    }

    /// 物理网卡（en*）和隧道（utun*）都要，虚拟桥接/调试接口不要
    private static func isPhysicalOrTunnel(_ name: String) -> Bool {
        if name.hasPrefix("en") || name.hasPrefix("utun") || name.hasPrefix("ppp") {
            return true
        }
        let skipPrefixes = ["lo", "awdl", "llw", "bridge", "gif", "stf", "XHC", "ap", "vmenet"]
        return !skipPrefixes.contains { name.hasPrefix($0) }
    }

    private static func displayName(for name: String, isWiFi: Bool) -> String {
        if isWiFi { return "\(name) · Wi-Fi" }
        if name.hasPrefix("utun") { return "\(name) · VPN" }
        if name == "en0" { return "\(name) · 以太网" }
        return name
    }
}
