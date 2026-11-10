import AppKit
import SwiftUI
import Combine

/// 状态栏总控。
///
/// v0.2 起每个模块是**独立的 NSStatusItem**，而不是把所有数值拼进一张图：
/// 这样可以分别开关、分别占位，也不会因为一个模块太长把整条撑爆。
///
/// 排序依赖 NSStatusBar 的创建顺序——新 item 会插在已有 item 的左侧，
/// 所以这里按设置顺序**反向**创建，最终从左到右就是设置里看到的顺序。
final class StatusItemController: NSObject {

    private var items: [ModuleKind: NSStatusItem] = [:]
    private var currentSignature = ""

    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private weak var anchorItem: NSStatusItem?

    private let settings = Settings.shared
    private let sampler = Sampler()

    override init() {
        super.init()
        configurePopover()

        sampler.onUpdate = { [weak self] in
            self?.renderAll()
        }
        sampler.start()
        observeChanges()
        syncItems(force: true)
    }

    // MARK: - 初始化

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 368, height: 660)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(store: sampler,
                                    settings: settings,
                                    onOpenSettings: { [weak self] in self?.openSettings() })
        )
    }

    private func observeChanges() {
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在属性真正改动前触发，延后一拍再读
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.sampler.restart()
                    self.syncItems()
                    self.renderAll()
                }
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    // MARK: - 条目管理

    private func syncItems(force: Bool = false) {
        let modules = settings.menuBarModules
        let signature = modules.map(\.rawValue).joined(separator: ",")
        guard force || signature != currentSignature else { return }
        currentSignature = signature

        for (_, item) in items {
            NSStatusBar.system.removeStatusItem(item)
        }
        items.removeAll()

        // 反向创建：新 item 出现在已有 item 的左侧，反过来建才是设置的顺序
        for module in modules.reversed() {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(handleClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            items[module] = item
        }
        renderAll()
    }

    private func renderAll() {
        for (module, item) in items {
            guard let segment = segment(for: module) else {
                item.isVisible = false
                continue
            }
            item.isVisible = true
            item.button?.image = MenuBarRenderer.image(for: [segment])
            item.button?.toolTip = tooltip(for: module)
        }

        // 全都取不到数据时（比如刚启动、硬件都不支持），至少留一个能点的入口
        if items.values.allSatisfy({ !$0.isVisible }), let first = items.first {
            first.value.isVisible = true
            let fallback = MenuBarSegment(value: "◍", valueColor: .labelColor, sparkline: [])
            first.value.button?.image = MenuBarRenderer.image(for: [fallback])
        }
    }

    // MARK: - 每模块的内容

    private func segment(for module: ModuleKind) -> MenuBarSegment? {
        let withGraph = settings.showGraphInMenuBar
        let compact = settings.compactMenuBar

        switch module {
        case .cpu:
            let fraction = sampler.cpu.usage
            return MenuBarSegment(
                label: compact ? "" : "CPU",
                value: String(format: "%3.0f%%", fraction * 100),
                valueColor: loadColor(fraction),
                sparkline: withGraph ? sampler.cpuHistory.suffix(26) : [],
                sparkColor: loadColor(fraction)
            )

        case .gpu:
            guard sampler.gpu.available else { return nil }
            let fraction = sampler.gpu.utilization
            return MenuBarSegment(
                label: compact ? "" : "GPU",
                value: String(format: "%3.0f%%", fraction * 100),
                valueColor: loadColor(fraction),
                sparkline: withGraph ? sampler.gpuHistory.suffix(26) : [],
                sparkColor: .systemIndigo
            )

        case .memory:
            let fraction = sampler.memory.usage
            return MenuBarSegment(
                label: compact ? "" : "MEM",
                value: String(format: "%3.0f%%", fraction * 100),
                valueColor: loadColor(fraction),
                sparkline: withGraph ? sampler.memoryHistory.suffix(26) : [],
                sparkColor: .systemPurple
            )

        case .network:
            let down = Format.compactRate(sampler.network.downBytesPerSec)
            let up = Format.compactRate(sampler.network.upBytesPerSec)
            return MenuBarSegment(
                value: "↓\(down) ↑\(up)",
                valueColor: .labelColor,
                sparkline: withGraph ? sampler.downHistory.suffix(26) : [],
                sparkColor: .systemBlue
            )

        case .disk:
            let fraction = sampler.disk.usage
            return MenuBarSegment(
                label: compact ? "" : "SSD",
                value: String(format: "%3.0f%%", fraction * 100),
                valueColor: loadColor(fraction),
                sparkline: [],
                sparkColor: .systemTeal
            )

        case .battery:
            guard let battery = sampler.battery else { return nil }
            return MenuBarSegment(
                label: compact ? "" : "BAT",
                value: String(format: "%3.0f%%", battery.percent),
                valueColor: batteryColor(battery),
                sparkline: [],
                sparkColor: .systemGreen
            )

        case .sensors:
            guard let temperature = sampler.sensors.cpuTemperature else { return nil }
            return MenuBarSegment(
                label: "",
                value: String(format: "%.0f°C", temperature),
                valueColor: temperatureColor(temperature),
                sparkline: [],
                sparkColor: .systemOrange
            )

        case .clock:
            let formatter = DateFormatter()
            formatter.dateFormat = settings.clockShowsSeconds ? "HH:mm:ss" : "HH:mm"
            return MenuBarSegment(
                label: "",
                value: formatter.string(from: Date()),
                valueColor: .labelColor,
                sparkline: [],
                sparkColor: .systemGray
            )
        }
    }

    private func tooltip(for module: ModuleKind) -> String {
        switch module {
        case .cpu: return "CPU " + Format.percent(sampler.cpu.usage)
        case .gpu: return "GPU " + Format.percent(sampler.gpu.utilization)
        case .memory: return "内存 " + Format.percent(sampler.memory.usage)
        case .network: return "↓\(Format.rate(sampler.network.downBytesPerSec)) ↑\(Format.rate(sampler.network.upBytesPerSec))"
        case .disk: return "磁盘 " + Format.percent(sampler.disk.usage)
        case .battery: return "电池 " + String(format: "%.0f%%", sampler.battery?.percent ?? 0)
        case .sensors: return "温度 " + (sampler.sensors.cpuTemperature.map { String(format: "%.1f°C", $0) } ?? "—")
        case .clock: return "当前时间"
        }
    }

    private func loadColor(_ fraction: Double) -> NSColor {
        if fraction >= 0.85 { return .systemRed }
        if fraction >= 0.6 { return .systemOrange }
        return .labelColor
    }

    private func batteryColor(_ battery: BatterySample) -> NSColor {
        if battery.isCharging { return .systemGreen }
        if battery.percent <= 10 { return .systemRed }
        if battery.percent <= 20 { return .systemOrange }
        return .labelColor
    }

    private func temperatureColor(_ celsius: Double) -> NSColor {
        if celsius >= 85 { return .systemRed }
        if celsius >= 70 { return .systemOrange }
        return .labelColor
    }

    // MARK: - 交互

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let item = items.first(where: { $0.value.button === sender })?.value else { return }
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            showContextMenu(for: item)
        } else {
            togglePopover(from: item)
        }
    }

    private func togglePopover(from item: NSStatusItem) {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            if anchorItem === item { return }
        }
        anchorItem = item
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContextMenu(for item: NSStatusItem) {
        guard let button = item.button, let event = NSApp.currentEvent else { return }
        let menu = buildMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        add(to: menu, title: "打开面板", action: #selector(openPanel))
        add(to: menu, title: "立即刷新", action: #selector(refreshNow))
        menu.addItem(.separator())

        // 模块勾选子菜单，省得为了关掉一项去开设置
        let modulesItem = NSMenuItem(title: "状态栏项目", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for module in ModuleKind.allCases {
            let entry = NSMenuItem(title: module.title, action: #selector(toggleModule(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = module.rawValue
            entry.state = settings.menuBarModules.contains(module) ? .on : .off
            submenu.addItem(entry)
        }
        modulesItem.submenu = submenu
        menu.addItem(modulesItem)

        menu.addItem(.separator())
        add(to: menu, title: "设置…", action: #selector(openSettings), key: ",")
        add(to: menu, title: "关于 Matrix", action: #selector(openAbout))
        menu.addItem(.separator())
        add(to: menu, title: "退出 Matrix", action: #selector(quitApp), key: "q")
        return menu
    }

    private func add(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleModule(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let module = ModuleKind(rawValue: raw) else { return }
        settings.toggleModule(module)
    }

    @objc private func openPanel() {
        guard let item = items.values.first(where: { $0.isVisible }) ?? items.values.first else { return }
        togglePopover(from: item)
    }

    @objc private func refreshNow() {
        sampler.restart()
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, alerts: sampler.alerts))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Matrix 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 560))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Matrix",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0",
            .credits: NSAttributedString(string: "macOS 菜单栏系统监视器")
        ])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func themeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.renderAll()
        }
    }
}
