import Foundation
import IOKit

/// 电池信息统一从 IORegistry 的 AppleSmartBattery 节点取：
/// 电量、充放电、剩余时间、循环次数、健康度、温度都在同一份属性字典里，
/// 不用再混一套 IOPowerSources 快照 API。台式机取不到节点 → 返回 nil，界面上整块隐藏。
final class BatteryReader {

    func sample() -> BatterySample? {
        guard let registry = Self.smartBatteryProperties() else { return nil }

        // 容量对（同一单位即可做比值）：优先用 mAh 的 Raw 字段
        let current = (registry["AppleRawCurrentCapacity"] as? NSNumber)?.doubleValue
            ?? (registry["CurrentCapacity"] as? NSNumber)?.doubleValue
        let maximum = (registry["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue
            ?? (registry["MaxCapacity"] as? NSNumber)?.doubleValue

        guard let current, let maximum, maximum > 0 else { return nil }

        var sample = BatterySample()
        sample.percent = min(100, max(0, current / maximum * 100))
        sample.isCharging = (registry["IsCharging"] as? Bool) ?? false
        sample.isPluggedIn = (registry["ExternalConnected"] as? Bool) ?? false

        if sample.isCharging {
            let minutes = (registry["TimeToFullCharge"] as? NSNumber)?.intValue ?? -1
            sample.timeRemainingMinutes = minutes > 0 ? minutes : nil
        } else if !sample.isPluggedIn {
            let minutes = (registry["TimeRemaining"] as? NSNumber)?.intValue ?? -1
            sample.timeRemainingMinutes = minutes > 0 ? minutes : nil
        }

        if let cycles = registry["CycleCount"] as? NSNumber {
            sample.cycleCount = cycles.intValue
        }

        if let design = (registry["DesignCapacity"] as? NSNumber)?.doubleValue,
           design > 0,
           let rawMaximum = (registry["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue,
           rawMaximum > 0,
           rawMaximum <= design * 1.5 {
            sample.healthPercent = min(100, rawMaximum / design * 100)
        }

        // Temperature 的单位是 0.1K
        if let raw = (registry["Temperature"] as? NSNumber)?.doubleValue, raw > 0 {
            let celsius = raw / 10.0 - 273.15
            if celsius > 0, celsius < 90 {
                sample.temperatureCelsius = celsius
            }
        }

        // Amperage 单位 mA（放电为负），Voltage 单位 mV
        if let amperage = (registry["Amperage"] as? NSNumber)?.doubleValue, amperage != 0 {
            sample.amperageMilliAmps = amperage
        }
        if let voltage = (registry["Voltage"] as? NSNumber)?.doubleValue, voltage > 0 {
            sample.voltageMilliVolts = voltage
        }

        return sample
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}
