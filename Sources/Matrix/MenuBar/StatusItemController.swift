import AppKit
import SwiftUI
import Combine

/// 状态栏条目 + 弹窗面板 + 设置窗口的总控。
final class StatusItemController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let settings = Settings.shared
    private let sampler = Sampler()

    override init() {
        super.init()
        configureStatusItem()
        configurePopover()

        sampler.onUpdate = { [weak self] in
            self?.renderStatusItem()
        }
        sampler.start()
        observeChanges()
        renderStatusItem()
    }

    // MARK: - 初始化

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Matrix 系统监视"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 344, height: 566)
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
                    self.renderStatusItem()
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

    // MARK: - 状态栏绘制

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let segments = buildSegments()

        if let image = MenuBarRenderer.image(for: segments) {
            button.image = image
            button.appearsDisabled = false
        } else {
            // 一个模块都没选时，至少留个可点的图标
            let image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Matrix")
            image?.isTemplate = true
            button.image = image
        }
        statusItem.length = NSStatusItem.variableLength
    }

    private func buildSegments() -> [MenuBarSegment] {
        var segments: [MenuBarSegment] = []
        let useGraph = settings.showGraphInMenuBar
        let compact = settings.compactMenuBar

        for module in settings.menuBarModules {
            switch module {
            case .cpu:
                let fraction = sampler.cpu.usage
                segments.append(MenuBarSegment(
                    label: compact ? "" : "CPU",
                    value: String(format: "%3.0f%%", fraction * 100),
                    valueColor: loadColor(fraction),
                    sparkline: useGraph ? sampler.cpuHistory.suffix(28) : [],
                    sparkColor: loadColor(fraction)
                ))

            case .memory:
                let fraction = sampler.memory.usage
                segments.append(MenuBarSegment(
                    label: compact ? "" : "MEM",
                    value: String(format: "%3.0f%%", fraction * 100),
                    valueColor: loadColor(fraction),
                    sparkline: useGraph ? sampler.memoryHistory.suffix(28) : [],
                    sparkColor: .systemPurple
                ))

            case .network:
                let down = Format.compactRate(sampler.network.downBytesPerSec)
                let up = Format.compactRate(sampler.network.upBytesPerSec)
                segments.append(MenuBarSegment(
                    value: "↓\(down) ↑\(up)",
                    valueColor: .labelColor,
                    sparkline: useGraph ? sampler.downHistory.suffix(28) : [],
                    sparkColor: .systemBlue
                ))

            case .disk:
                let fraction = sampler.disk.usage
                segments.append(MenuBarSegment(
                    label: compact ? "" : "SSD",
                    value: String(format: "%3.0f%%", fraction * 100),
                    valueColor: loadColor(fraction),
                    sparkline: [],
                    sparkColor: .systemTeal
                ))

            case .battery:
                guard let battery = sampler.battery else { continue }
                segments.append(MenuBarSegment(
                    label: compact ? "" : "BAT",
                    value: String(format: "%3.0f%%", battery.percent),
                    valueColor: batteryColor(battery),
                    sparkline: [],
                    sparkColor: .systemGreen
                ))

            case .sensors:
                guard let temperature = sampler.sensors.cpuTemperature else { continue }
                segments.append(MenuBarSegment(
                    label: "",
                    value: String(format: "%.0f°C", temperature),
                    valueColor: temperatureColor(temperature),
                    sparkline: [],
                    sparkColor: .systemOrange
                ))
            }
        }
        return segments
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

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        addItem(to: menu, title: "打开面板", action: #selector(openPanel))
        menu.addItem(.separator())
        addItem(to: menu, title: "设置…", action: #selector(openSettings), key: ",")
        addItem(to: menu, title: "关于 Matrix", action: #selector(openAbout))
        menu.addItem(.separator())
        addItem(to: menu, title: "退出 Matrix", action: #selector(quitApp), key: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // 立刻清空，否则左键点不开 popover
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPanel() {
        togglePopover()
    }

    @objc private func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Matrix 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Matrix",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0",
            .credits: NSAttributedString(string: "macOS 菜单栏系统监视器")
        ])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func themeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.renderStatusItem()
        }
    }
}
