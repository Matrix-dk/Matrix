import Foundation
import Combine

enum ModuleKind: String, CaseIterable, Identifiable, Codable {
    case cpu
    case memory
    case network
    case disk
    case battery
    case sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "磁盘"
        case .battery: return "电池"
        case .sensors: return "传感器"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        case .sensors: return "thermometer.medium"
        }
    }
}

/// 全局配置。直接落 UserDefaults，改动即时生效（菜单栏下次刷新就会用新配置）。
final class Settings: ObservableObject {

    static let shared = Settings()

    private enum Key {
        static let modules = "menuBarModules"
        static let interval = "refreshInterval"
        static let graph = "showGraphInMenuBar"
        static let compact = "compactMenuBar"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults = UserDefaults.standard

    /// 状态栏里显示哪些模块，顺序即显示顺序
    @Published var menuBarModules: [ModuleKind] {
        didSet { saveModules() }
    }

    /// 采样间隔（秒），实际使用时再夹到 1...10
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Key.interval) }
    }

    /// 状态栏是否画迷你曲线
    @Published var showGraphInMenuBar: Bool {
        didSet { defaults.set(showGraphInMenuBar, forKey: Key.graph) }
    }

    /// 紧凑模式：网络只显示箭头+数值，不带 "CPU/内存" 字样
    @Published var compactMenuBar: Bool {
        didSet { defaults.set(compactMenuBar, forKey: Key.compact) }
    }

    @Published var launchAtLogin: Bool {
        didSet { LaunchAtLogin.setEnabled(launchAtLogin) }
    }

    private init() {
        let stored = defaults.stringArray(forKey: Key.modules)
            ?? [ModuleKind.cpu.rawValue, ModuleKind.memory.rawValue, ModuleKind.network.rawValue]
        var modules = stored.compactMap { ModuleKind(rawValue: $0) }
        if modules.isEmpty {
            modules = [.cpu, .memory, .network]
        }
        menuBarModules = modules

        let interval = defaults.object(forKey: Key.interval) as? Double ?? 2
        refreshInterval = min(max(interval, 1), 10)

        showGraphInMenuBar = defaults.object(forKey: Key.graph) as? Bool ?? true
        compactMenuBar = defaults.object(forKey: Key.compact) as? Bool ?? false
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func saveModules() {
        defaults.set(menuBarModules.map { $0.rawValue }, forKey: Key.modules)
    }

    func toggleModule(_ module: ModuleKind) {
        if let index = menuBarModules.firstIndex(of: module) {
            menuBarModules.remove(at: index)
        } else {
            menuBarModules.append(module)
        }
    }
}
