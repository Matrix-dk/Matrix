import SwiftUI
import AppKit

struct SettingsView: View {

    @ObservedObject var settings: Settings
    @ObservedObject var alerts: AlertEngine

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("常规", systemImage: "gearshape") }
            menuBarTab
                .tabItem { Label("状态栏", systemImage: "menubar.rectangle") }
            alertsTab
                .tabItem { Label("告警", systemImage: "bell.badge") }
            dataTab
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - 常规

    private var generalTab: some View {
        Form {
            Section {
                Picker("刷新间隔", selection: $settings.refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                }
                Toggle("状态栏显示迷你曲线", isOn: $settings.showGraphInMenuBar)
                Toggle("紧凑模式（不显示 CPU/MEM 字样）", isOn: $settings.compactMenuBar)
                Toggle("时间显示到秒", isOn: $settings.clockShowsSeconds)
            } header: {
                Text("外观")
            } footer: {
                Text("采样间隔越短曲线越细，CPU 占用也越高。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("开机自动启动", isOn: $settings.launchAtLogin)
            } header: {
                Text("启动")
            } footer: {
                Text("需要 app 已放到「应用程序」目录，开机自启才稳定生效。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("查询公网 IP", isOn: $settings.publicIPEnabled)
                Stepper(value: $settings.processCount, in: 3 ... 12) {
                    Text("面板显示 \(settings.processCount) 个进程")
                }
                TextField("隐藏的网卡，逗号分隔（如 utun3, en5）",
                          text: hiddenInterfacesBinding)
            } header: {
                Text("数据")
            } footer: {
                Text("公网 IP 会向 api.ipify.org 发请求，默认关闭；进程数只影响面板显示。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                TextField("额外时区，逗号分隔（如 Asia/Tokyo, Europe/London）",
                          text: clockZonesBinding)
            } header: {
                Text("时钟")
            } footer: {
                Text("填 TimeZone 标识符，会显示在面板的时间卡片里。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var clockZonesBinding: Binding<String> {
        Binding(
            get: { settings.clockZoneIdentifiers.joined(separator: ", ") },
            set: { raw in
                settings.clockZoneIdentifiers = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && TimeZone(identifier: $0) != nil }
            }
        )
    }

    private var hiddenInterfacesBinding: Binding<String> {
        Binding(
            get: { settings.hiddenInterfaces.joined(separator: ", ") },
            set: { raw in
                settings.hiddenInterfaces = raw
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - 状态栏

    private var hiddenModules: [ModuleKind] {
        ModuleKind.allCases.filter { !settings.menuBarModules.contains($0) }
    }

    private var menuBarTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("显示样式")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            Text(settings.menuBarStyle.hint)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 8)

            Divider()

            List {
                Section {
                    ForEach(settings.menuBarModules) { module in
                        moduleRow(module, enabled: true)
                    }
                    .onMove { indices, newOffset in
                        settings.moveModules(from: indices, to: newOffset)
                    }
                } header: {
                    Text("已显示 · 拖动行可调整左右顺序")
                }

                if !hiddenModules.isEmpty {
                    Section {
                        ForEach(hiddenModules) { module in
                            moduleRow(module, enabled: false)
                        }
                    } header: {
                        Text("未显示")
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            Text("每个模块是独立的状态栏条目；硬件不支持时（比如台式机没有电池）会自动隐藏。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
    }

    private func moduleRow(_ module: ModuleKind, enabled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: module.symbolName)
                .frame(width: 18)
                .foregroundColor(enabled ? .accentColor : .secondary)
            Text(module.title)
            Spacer()

            if enabled {
                Button {
                    settings.moveModule(module, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(settings.menuBarModules.first == module)

                Button {
                    settings.moveModule(module, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(settings.menuBarModules.last == module)
            }

            Toggle("", isOn: binding(for: module))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    private func binding(for module: ModuleKind) -> Binding<Bool> {
        Binding(
            get: { settings.menuBarModules.contains(module) },
            set: { isOn in
                if isOn {
                    if !settings.menuBarModules.contains(module) {
                        settings.menuBarModules.append(module)
                    }
                } else {
                    settings.menuBarModules.removeAll { $0 == module }
                }
            }
        )
    }

    // MARK: - 告警

    private var alertsTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: alerts.notificationsAvailable ? "bell.badge" : "bell.slash")
                    .foregroundColor(alerts.notificationsAuthorized ? .green : .secondary)
                Text(notificationStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    if settings.alerts.isEmpty {
                        Text("还没有规则。点下面的「添加规则」开始。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 30)
                    }

                    ForEach(settings.alerts) { rule in
                        AlertRuleRow(rule: ruleBinding(rule.id),
                                     onDelete: { delete(rule.id) })
                        Divider()
                    }
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button {
                    settings.alerts.append(AlertRule())
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                Spacer()
                Text("超限需持续指定秒数才触发，触发后进入冷却期。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private var notificationStatusText: String {
        if !alerts.notificationsAvailable {
            return "当前以命令行方式运行，系统通知不可用（打包成 .app 后才有）。"
        }
        return alerts.notificationsAuthorized
            ? "系统通知已授权，触发时会弹出横幅。"
            : "未获得通知权限，触发只会记录在应用内。请在「系统设置 › 通知」里允许 Matrix。"
    }

    private func ruleBinding(_ id: UUID) -> Binding<AlertRule> {
        Binding(
            get: { settings.alerts.first(where: { $0.id == id }) ?? AlertRule() },
            set: { newValue in
                if let index = settings.alerts.firstIndex(where: { $0.id == id }) {
                    settings.alerts[index] = newValue
                }
            }
        )
    }

    private func delete(_ id: UUID) {
        settings.alerts.removeAll { $0.id == id }
    }

    // MARK: - 历史

    private var dataTab: some View {
        Form {
            Section {
                Toggle("记录历史数据", isOn: $settings.historyEnabled)
                Toggle("传感器显示全部 key", isOn: $settings.showAllSensors)
            } header: {
                Text("采集")
            } footer: {
                Text("历史按分钟聚合，保留 7 天；1 小时视图用秒级数据，越跑越细。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                LabeledContent("已记录", value: "\(HistoryStore.shared.totalRecordedCount) 条（分钟粒度）")
                if let earliest = HistoryStore.shared.earliestDate {
                    LabeledContent("最早", value: Format.detailDate(earliest))
                }
                LabeledContent("存储位置") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.selectFile(nil,
                                                      inFileViewerRootedAtPath: HistoryStore.shared.storageDescription)
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("历史")
            }

            Section {
                Button("清除全部历史数据", role: .destructive) {
                    HistoryStore.shared.clearAll()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 单条告警规则

private struct AlertRuleRow: View {
    @Binding var rule: AlertRule
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("", isOn: $rule.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                Picker("", selection: metricBinding) {
                    ForEach(AlertMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .labelsHidden()
                .frame(width: 120)

                Picker("", selection: $rule.comparison) {
                    ForEach(AlertComparison.allCases) { comparison in
                        Text(comparison.title).tag(comparison)
                    }
                }
                .labelsHidden()
                .frame(width: 72)

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                Slider(value: $rule.threshold, in: rule.metric.range)
                Text(thresholdText)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }

            HStack(spacing: 14) {
                Stepper(value: $rule.sustainedSeconds, in: 5 ... 600, step: 5) {
                    Text("持续 \(Int(rule.sustainedSeconds)) 秒")
                        .font(.caption)
                }
                Stepper(value: $rule.cooldownMinutes, in: 1 ... 120, step: 1) {
                    Text("冷却 \(Int(rule.cooldownMinutes)) 分")
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.enabled ? 1 : 0.55)
    }

    /// 换指标时把阈值和比较方向重置成该指标的合理默认值
    private var metricBinding: Binding<AlertMetric> {
        Binding(
            get: { rule.metric },
            set: { newValue in
                rule.metric = newValue
                rule.threshold = newValue.defaultThreshold
                rule.comparison = newValue.defaultComparison
            }
        )
    }

    private var thresholdText: String {
        let unit = rule.metric.unit
        return rule.threshold == rule.threshold.rounded()
            ? String(format: "%.0f%@", rule.threshold, unit)
            : String(format: "%.1f%@", rule.threshold, unit)
    }
}
