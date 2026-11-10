import Foundation
import CoreWLAN

/// Wi-Fi 详情走 CoreWLAN。
///
/// SSID 在 macOS 14 之后需要定位权限才会返回，拿不到时保持 nil（界面显示「—」），
/// 不主动弹权限框——对一个系统监视工具来说这个打扰不值得。
/// RSSI / 噪声 / 信道 / 协商速率都不需要权限。
final class WiFiReader {

    private let client = CWWiFiClient.shared()

    func sample() -> WiFiSample {
        var sample = WiFiSample()
        guard let interface = client.interface() else { return sample }

        sample.available = true
        sample.powered = interface.powerOn()
        guard sample.powered else { return sample }

        sample.ssid = interface.ssid()

        let rssi = interface.rssiValue()
        if rssi < 0 { sample.rssi = rssi }

        let noise = interface.noiseMeasurement()
        if noise < 0 { sample.noise = noise }

        sample.channel = Self.channelText(interface.wlanChannel())

        let rate = interface.transmitRate()
        if rate > 0 { sample.txRateMbps = rate }

        sample.phyMode = Self.phyModeText(interface.activePHYMode())
        sample.security = Self.securityText(interface.security())
        return sample
    }

    /// 主 Wi-Fi 接口名（en0 之类），用来在接口列表里标注
    var interfaceName: String? {
        guard let interface = client.interface() else { return nil }
        return interface.interfaceName
    }

    private static func channelText(_ channel: CWChannel?) -> String? {
        guard let channel else { return nil }
        let band: String
        switch channel.channelBand.rawValue {
        case 1: band = "2.4G"
        case 2: band = "5G"
        case 3: band = "6G"
        default: band = ""
        }
        return band.isEmpty ? "\(channel.channelNumber)" : "\(channel.channelNumber) · \(band)"
    }

    private static func phyModeText(_ mode: CWPHYMode) -> String? {
        // 用 rawValue 而不是 case 名，避免不同 SDK 版本枚举名差异
        switch mode.rawValue {
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "802.11n"
        case 5: return "802.11ac"
        case 6: return "802.11ax"
        default: return nil
        }
    }

    private static func securityText(_ security: CWSecurity) -> String? {
        switch security.rawValue {
        case 0: return "开放"
        case 1: return "WEP"
        case 2, 3, 4, 5: return "WPA/WPA2 个人级"
        case 7, 8, 9, 10: return "WPA/WPA2 企业级"
        case 11, 12, 13: return "WPA3"
        default: return nil
        }
    }
}
