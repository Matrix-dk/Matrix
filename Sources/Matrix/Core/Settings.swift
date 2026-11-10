import Foundation
import Combine

// MARK: - 模块

enum ModuleKind: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case network
    case disk
    case battery
    case sensors
    case clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "磁盘"
        case .battery: return "电池"
        case .sensors: return "传感器"
        case .clock: return "时间"
        }
    }

    var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.100"
        case .sensors: return "thermometer.medium"
        case .clock: return "clock"
        }
    }

    /// 该模块是否依赖硬件能力，取不到时状态栏自动隐藏
    var requiresHardware: Bool {
        switch self {
        case .gpu, .battery, .sensors: return true
        default: return false
        }
    }
}

// MARK: - 状态栏显示样式

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case text          // CPU 12%
    case valueOnly     // 12%
    case icon          // 只有图标
    case ring          // 圆环进度 + 数值

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "标签 + 数值"
        case .valueOnly: return "只显示数值"
        case .icon: return "只显示图标"
        case .ring: return "圆环 + 数值"
        }
    }

    var hint: String {
        switch self {
        case .text: return "默认样式，信息最全但最占宽度。"
        case .valueOnly: return "省掉 CPU/MEM 字样，靠图标本身区分。"
        case .icon: return "最省宽度，鼠标悬停看 tooltip。"
        case .ring: return "环形进度条，接近 iStat 的图形模式。"
        }
    }
}

// MARK: - 告警规则

enum AlertMetric: String, CaseIterable, Identifiable, Codable {
    case cpu
    case gpu
    case memory
    case disk
    case temperature
    case batteryLow
    case networkDown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU 占用"
        case .gpu: return "GPU 占用"
        case .memory: return "内存占用"
        case .disk: return "磁盘占用"
        case .temperature: return "CPU 温度"
        case .batteryLow: return "电池电量"
        case .networkDown: return "下行速率"
        }
    }

    var unit: String {
        switch self {
        case .cpu, .gpu, .memory, .disk, .batteryLow: return "%"
        case .temperature: return "°C"
        case .networkDown: return "MB/s"
        }
    }

    /// 该指标取值的合理区间，用于滑杆和输入校验
    var range: ClosedRange<Double> {
        switch self {
        case .cpu, .gpu, .memory, .disk, .batteryLow: return 0...100
        case .temperature: return 30...110
        case .networkDown: return 0.1...100
        }
    }

    var defaultThreshold: Double {
        switch self {
        case .cpu: return 85
        case .gpu: return 90
        case .memory: return 90
        case .disk: return 90
        case .temperature: return 90
        case .batteryLow: return 20
        case .networkDown: return 10
        }
    }

    /// 电量类指标天然是「低于」，其它是「高于」
    var defaultComparison: AlertComparison {
        self == .batteryLow ? .below : .above
    }
}

enum AlertComparison: String, CaseIterable, Identifiable, Codable {
    case above
    case below

    var id: String { rawValue }
    var title: String { self == .above ? "高于" : "低于" }
}

struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var enabled: Bool = true
    var metric: AlertMetric = .cpu
    var comparison: AlertComparison = .above
    var threshold: Double = 85
    /// 需要持续多久才触发，避免抖动误报
    var sustainedSeconds: Double = 30
    /// 触发后的静默时间
    var cooldownMinutes: Double = 5

    var summary: String {
        "\(metric.title) \(comparison.title) \(trimmedThreshold)\(metric.unit)"
    }

    private var trimmedThreshold: String {
        threshold == threshold.rounded()
            ? String(format: "%.0f", threshold)
            : String(format: "%.1f", threshold)
    }
}

struct AlertEvent: Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var body: String
    var metric: AlertMetric
}

// MARK: - 配置

/// 全局配置。直接落 UserDefaults，改动即时生效。
final class Settings: ObservableObject {

    static let shared = Settings()

    private enum Key {
        static let modules = "menuBarModules"
        static let interval = "refreshInterval"
        static let graph = "showGraphInMenuBar"
        static let compact = "compactMenuBar"
        static let launchAtLogin = "launchAtLogin"
        static let alerts = "alertRules"
        static let history = "historyEnabled"
        static let sensorsAll = "showAllSensors"
        static let processSort = "processSort"
        static let clockSeconds = "clockShowSeconds"
        static let style = "menuBarStyle"
        static let publicIP = "publicIPEnabled"
        static let processCount = "processCount"
        static let clockZones = "clockZoneIdentifiers"
        static let hiddenIfaces = "hiddenInterfaces"
    }

    private let defaults = UserDefaults.standard

    /// 状态栏里显示哪些模块，顺序即从左到右的显示顺序
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

    /// 紧凑模式：不显示 CPU/MEM 之类的前缀字样
    @Published var compactMenuBar: Bool {
        didSet { defaults.set(compactMenuBar, forKey: Key.compact) }
    }

    @Published var launchAtLogin: Bool {
        didSet { LaunchAtLogin.setEnabled(launchAtLogin) }
    }

    /// 告警规则
    @Published var alerts: [AlertRule] {
        didSet { saveAlerts() }
    }

    /// 是否落盘历史数据
    @Published var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.history) }
    }

    /// 传感器面板是否展示全部 key（默认只显示前若干个温度）
    @Published var showAllSensors: Bool {
        didSet { defaults.set(showAllSensors, forKey: Key.sensorsAll) }
    }

    @Published var processSort: ProcessSort {
        didSet { defaults.set(processSort.rawValue, forKey: Key.processSort) }
    }

    @Published var clockShowsSeconds: Bool {
        didSet { defaults.set(clockShowsSeconds, forKey: Key.clockSeconds) }
    }

    /// 状态栏显示样式
    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.style) }
    }

    /// 是否解析公网 IP（会向 ipify 发请求，可关）
    @Published var publicIPEnabled: Bool {
        didSet { defaults.set(publicIPEnabled, forKey: Key.publicIP) }
    }

    /// 面板里显示几个进程
    @Published var processCount: Int {
        didSet { defaults.set(processCount, forKey: Key.processCount) }
    }

    /// 面板时钟卡片里额外显示哪些时区（TimeZone 标识符）
    @Published var clockZoneIdentifiers: [String] {
        didSet { defaults.set(clockZoneIdentifiers, forKey: Key.clockZones) }
    }

    /// 不希望在接口列表里看到的网卡名
    @Published var hiddenInterfaces: [String] {
        didSet { defaults.set(hiddenInterfaces, forKey: Key.hiddenIfaces) }
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

        historyEnabled = defaults.object(forKey: Key.history) as? Bool ?? true
        showAllSensors = defaults.object(forKey: Key.sensorsAll) as? Bool ?? false
        clockShowsSeconds = defaults.object(forKey: Key.clockSeconds) as? Bool ?? false

        let sortRaw = defaults.string(forKey: Key.processSort) ?? ProcessSort.cpu.rawValue
        processSort = ProcessSort(rawValue: sortRaw) ?? .cpu

        let styleRaw = defaults.string(forKey: Key.style) ?? MenuBarStyle.text.rawValue
        menuBarStyle = MenuBarStyle(rawValue: styleRaw) ?? .text
        publicIPEnabled = defaults.object(forKey: Key.publicIP) as? Bool ?? false
        processCount = defaults.object(forKey: Key.processCount) as? Int ?? 6
        clockZoneIdentifiers = defaults.stringArray(forKey: Key.clockZones) ?? []
        hiddenInterfaces = defaults.stringArray(forKey: Key.hiddenIfaces) ?? []

        if let data = defaults.data(forKey: Key.alerts),
           let decoded = try? JSONDecoder().decode([AlertRule].self, from: data) {
            alerts = decoded
        } else {
            alerts = Settings.defaultAlerts
        }
    }

    private static var defaultAlerts: [AlertRule] {
        [
            AlertRule(enabled: true,
                      metric: .cpu,
                      comparison: .above,
                      threshold: 90,
                      sustainedSeconds: 60,
                      cooldownMinutes: 10),
            AlertRule(enabled: true,
                      metric: .batteryLow,
                      comparison: .below,
                      threshold: 15,
                      sustainedSeconds: 60,
                      cooldownMinutes: 30)
        ]
    }

    private func saveModules() {
        defaults.set(menuBarModules.map(\.rawValue), forKey: Key.modules)
    }

    private func saveAlerts() {
        if let data = try? JSONEncoder().encode(alerts) {
            defaults.set(data, forKey: Key.alerts)
        }
    }

    // MARK: - 模块操作

    func toggleModule(_ module: ModuleKind) {
        if let index = menuBarModules.firstIndex(of: module) {
            menuBarModules.remove(at: index)
        } else {
            menuBarModules.append(module)
        }
    }

    func moveModule(_ module: ModuleKind, by offset: Int) {
        guard let index = menuBarModules.firstIndex(of: module) else { return }
        let target = index + offset
        guard target >= 0, target < menuBarModules.count else { return }
        menuBarModules.swapAt(index, target)
    }

    /// 注意：这里自己实现移动而不是用 `Array.move(fromOffsets:toOffset:)`，
    /// 那个方法由 SwiftUI 提供，Settings 这层不该为了排序去依赖 SwiftUI。
    func moveModules(from source: IndexSet, to destination: Int) {
        var working = menuBarModules
        let moving = source.sorted().compactMap { index in
            index < working.count ? working[index] : nil
        }
        for index in source.sorted(by: >) where index < working.count {
            working.remove(at: index)
        }
        let removedBefore = source.filter { $0 < destination }.count
        let target = min(max(destination - removedBefore, 0), working.count)
        working.insert(contentsOf: moving, at: target)
        menuBarModules = working
    }
}
