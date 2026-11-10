import Foundation
import ServiceManagement

/// 开机自启。macOS 13+ 用 SMAppService；需要 app 已经以 .app 形式存在（SwiftPM 裸二进制无效）。
enum LaunchAtLogin {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    guard service.status != .enabled else { return }
                    try service.register()
                } else {
                    guard service.status == .enabled else { return }
                    try service.unregister()
                }
            } catch {
                NSLog("[Matrix] 设置开机自启失败: \(error.localizedDescription)")
            }
        }
    }
}
