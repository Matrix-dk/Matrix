import SwiftUI
import AppKit

struct DashboardView: View {

    @ObservedObject var store: Sampler
    @ObservedObject var settings: Settings
    var onOpenSettings: () -> Void = {}

    @AppStorage("historyRange") private var rangeRaw: String = TimeRange.hour.rawValue

    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .hour }
    private var history: HistoryStore { HistoryStore.shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    cpuCard
                    if store.gpu.available {
                        gpuCard
                    }
                    memoryCard
                    networkCard
                    diskCard
                    if let battery = store.battery {
                        batteryCard(battery)
                    }
                    sensorsCard
                    if settings.menuBarModules.contains(.clock) {
                        clockCard
                    }
                    processCard
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .frame(width: 368, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("Matrix")
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 6)

            Picker("", selection: $rangeRaw) {
                ForEach(TimeRange.allCases) { item in
                    Text(item.shortTitle).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 132)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            Text(store.isPaused ? "已暂停" : historyCaption)
                .font(.system(size: 9.5))
                .foregroundColor(store.isPaused ? .orange : .secondary)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var historyCaption: String {
        if !settings.historyEnabled { return "历史记录已关闭" }
        guard let earliest = history.earliestDate else { return "历史记录中…" }
        return "已记录 \(Format.uptime(Date().timeIntervalSince(earliest)))"
    }

    // MARK: - CPU

    private var cpuCard: some View {
        Card(title: "CPU",
             value: Format.percent(store.cpu.usage),
             detail: String(format: "负载 %.2f / %.2f / %.2f",
                            store.cpu.loadOne, store.cpu.loadFive, store.cpu.loadFifteen),
             accent: .orange) {
            VStack(spacing: 7) {
                RangeChart(values: chartValues(.cpu, fallback: store.cpuHistory.values),
                           color: .orange,
                           range: range,
                           ceiling: 1,
                           formatter: { Format.percent($0) })

                CoreBars(values: store.cpu.perCore)
                    .frame(height: 22)

                HStack {
                    Text("\(store.cpu.coreCount) 核")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("用户 \(Format.percent(store.cpu.user)) · 系统 \(Format.percent(store.cpu.system))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - GPU

    private var gpuCard: some View {
        Card(title: "GPU",
             value: Format.percent(store.gpu.utilization),
             detail: store.gpu.name,
             accent: .indigo) {
            VStack(spacing: 7) {
                RangeChart(values: chartValues(.gpu, fallback: store.gpuHistory.values),
                           color: .indigo,
                           range: range,
                           ceiling: 1,
                           formatter: { Format.percent($0) },
                           height: 34)

                UsageBar(fraction: store.gpu.utilization, color: .indigo)

                StatRow(label: "渲染器", value: Format.percent(store.gpu.renderUtilization))
                if store.gpu.usedMemory > 0 {
                    StatRow(label: "显存占用",
                            value: store.gpu.allocatedMemory > 0
                                ? "\(Format.bytes(store.gpu.usedMemory)) / \(Format.bytes(store.gpu.allocatedMemory))"
                                : Format.bytes(store.gpu.usedMemory))
                }
                if store.gpu.coreCount > 0 {
                    StatRow(label: "GPU 核心", value: "\(store.gpu.coreCount)")
                }
            }
        }
    }

    // MARK: - 内存

    private var memoryCard: some View {
        Card(title: "内存",
             value: Format.percent(store.memory.usage),
             detail: "\(Format.bytes(store.memory.used)) / \(Format.bytes(store.memory.total))",
             accent: .purple) {
            VStack(spacing: 7) {
                RangeChart(values: chartValues(.memory, fallback: store.memoryHistory.values),
                           color: .purple,
                           range: range,
                           ceiling: 1,
                           formatter: { Format.percent($0) },
                           height: 34)

                UsageBar(fraction: store.memory.usage, color: .purple)

                HStack(spacing: 6) {
                    Text("内存压力")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Pill(text: store.memory.pressure.title, color: pressureColor)
                }

                VStack(spacing: 3) {
                    StatRow(label: "App 内存", value: Format.bytes(store.memory.app))
                    StatRow(label: "联动内存", value: Format.bytes(store.memory.wired))
                    StatRow(label: "已压缩", value: Format.bytes(store.memory.compressed))
                    StatRow(label: "文件缓存", value: Format.bytes(store.memory.cached))
                    StatRow(label: "交换空间",
                            value: store.memory.swapTotal > 0
                                ? "\(Format.bytes(store.memory.swapUsed)) / \(Format.bytes(store.memory.swapTotal))"
                                : "未使用")
                    StatRow(label: "页面换入",
                            value: String(format: "%.0f 页/s", store.memory.pageInRate),
                            color: store.memory.pageInRate > 50 ? .orange : .secondary)
                    StatRow(label: "页面换出",
                            value: String(format: "%.0f 页/s", store.memory.pageOutRate),
                            color: store.memory.pageOutRate > 50 ? .orange : .secondary)
                }
            }
        }
    }

    private var pressureColor: Color {
        switch store.memory.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - 网络

    private var networkCard: some View {
        Card(title: "网络",
             value: "↓ " + Format.rate(store.network.downBytesPerSec),
             detail: store.network.interfaceName.isEmpty ? nil : store.network.interfaceName,
             accent: .blue) {
            VStack(spacing: 7) {
                RangeChart(values: chartValues(.netDown, fallback: store.downHistory.values),
                           color: .blue,
                           range: range,
                           formatter: { Format.compactRate($0) },
                           height: 34)

                StatRow(label: "下行", value: Format.rate(store.network.downBytesPerSec), color: .blue)
                StatRow(label: "上行", value: Format.rate(store.network.upBytesPerSec), color: .orange)
                HStack(spacing: 6) {
                    Text("本次开机累计")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text("↓\(Format.bytes(store.network.totalDown))  ↑\(Format.bytes(store.network.totalUp))")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Button {
                        store.resetNetworkTotals()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("把累计流量清零重新统计")
                }

                if !store.network.publicIP.isEmpty {
                    StatRow(label: "公网 IP", value: store.network.publicIP)
                }

                if !store.network.interfaces.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(Array(store.network.interfaces.prefix(4))) { item in
                        interfaceRow(item)
                    }
                }

                if store.wifi.available && store.wifi.powered {
                    Divider().opacity(0.4)
                    wifiBlock
                }
            }
        }
    }

    private func interfaceRow(_ item: InterfaceSample) -> some View {
        HStack(spacing: 5) {
            if item.isPrimary {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4)
            }
            Text(item.displayName)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("↓\(Format.compactRate(item.downBytesPerSec)) ↑\(Format.compactRate(item.upBytesPerSec))")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    private var wifiBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                SignalBars(level: store.wifi.signalBars,
                           color: store.wifi.signalBars <= 1 ? .red : .blue)
                Text(store.wifi.ssid ?? "Wi-Fi（SSID 需定位权限）")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let rssi = store.wifi.rssi {
                    Text("\(rssi) dBm")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            if let channel = store.wifi.channel {
                StatRow(label: "信道", value: channel)
            }
            if let rate = store.wifi.txRateMbps {
                StatRow(label: "协商速率", value: String(format: "%.0f Mbps", rate))
            }
            if let phy = store.wifi.phyMode {
                StatRow(label: "协议", value: phy)
            }
            if let noise = store.wifi.noise {
                StatRow(label: "噪声", value: "\(noise) dBm")
            }
        }
    }

    // MARK: - 磁盘

    private var diskCard: some View {
        Card(title: "磁盘",
             value: Format.percent(store.disk.usage),
             detail: "\(Format.bytes(store.disk.free)) 可用",
             accent: .teal) {
            VStack(spacing: 7) {
                UsageBar(fraction: store.disk.usage, color: .teal)
                StatRow(label: "读取", value: Format.rate(store.disk.readBytesPerSec), color: .blue)
                StatRow(label: "写入", value: Format.rate(store.disk.writeBytesPerSec), color: .orange)
                StatRow(label: "总容量",
                        value: "\(Format.bytes(store.disk.used)) / \(Format.bytes(store.disk.total))")

                if store.disk.volumes.count > 1 {
                    Divider().opacity(0.4)
                    ForEach(Array(store.disk.volumes.prefix(4))) { volume in
                        HStack(spacing: 6) {
                            Text(volume.name)
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Format.bytes(volume.free)) 可用")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundColor(volume.usage >= 0.9 ? .red : .secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 电池

    private func batteryCard(_ battery: BatterySample) -> some View {
        Card(title: "电池",
             value: Format.percent(battery.percent / 100),
             detail: battery.isCharging ? "充电中" : (battery.isPluggedIn ? "外接电源" : "使用电池"),
             accent: .green) {
            VStack(spacing: 7) {
                UsageBar(fraction: battery.percent / 100,
                         color: battery.percent <= 20 && !battery.isCharging ? .orange : .green)

                if let minutes = battery.timeRemainingMinutes {
                    StatRow(label: battery.isCharging ? "充满还需" : "剩余时间",
                            value: "\(minutes / 60) 小时 \(minutes % 60) 分")
                }
                if let cycles = battery.cycleCount {
                    StatRow(label: "循环次数", value: "\(cycles)")
                }
                if let health = battery.healthPercent {
                    StatRow(label: "健康度", value: String(format: "%.0f%%", health))
                }
                if let temperature = battery.temperatureCelsius {
                    StatRow(label: "电池温度", value: String(format: "%.1f°C", temperature))
                }
                if let watts = battery.powerWatts {
                    StatRow(label: "功率", value: String(format: "%.1f W", abs(watts)))
                }
            }
        }
    }

    // MARK: - 传感器

    private var sensorsCard: some View {
        Card(title: "传感器",
             value: store.sensors.cpuTemperature.map { String(format: "%.1f°C", $0) } ?? "—",
             detail: store.sensors.catalogueSize > 0 ? "\(store.sensors.catalogueSize) 个 key" : nil,
             accent: .pink) {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Text("温度")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(settings.showAllSensors ? "精简" : "全部") {
                        settings.showAllSensors.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5))
                    .foregroundColor(.accentColor)
                }

                if store.sensors.temperatures.isEmpty {
                    Text("当前机型读不到 SMC 温度")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                } else {
                    let limit = settings.showAllSensors ? store.sensors.temperatures.count : 6
                    ForEach(Array(store.sensors.temperatures.prefix(limit))) { item in
                        StatRow(label: "\(item.label)  ·  \(item.key)",
                                value: item.formatted,
                                color: UsageColor.temperature(item.value))
                    }
                    if !settings.showAllSensors, store.sensors.temperatures.count > 6 {
                        Text("另有 \(store.sensors.temperatures.count - 6) 项未显示")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                if !store.sensors.fans.isEmpty {
                    Divider().opacity(0.4)
                    ForEach(store.sensors.fans) { fan in
                        StatRow(label: fan.label,
                                value: String(format: "%.0f RPM", fan.value),
                                color: fan.value > 4000 ? .orange : .secondary)
                    }
                }

                if settings.showAllSensors {
                    if !store.sensors.powers.isEmpty {
                        Divider().opacity(0.4)
                        ForEach(Array(store.sensors.powers.prefix(4))) { item in
                            StatRow(label: "功率 \(item.key)", value: item.formatted)
                        }
                    }
                    if !store.sensors.voltages.isEmpty {
                        Divider().opacity(0.4)
                        ForEach(Array(store.sensors.voltages.prefix(4))) { item in
                            StatRow(label: "电压 \(item.key)", value: item.formatted)
                        }
                    }
                    if !store.sensors.currents.isEmpty {
                        Divider().opacity(0.4)
                        ForEach(Array(store.sensors.currents.prefix(4))) { item in
                            StatRow(label: "电流 \(item.key)", value: item.formatted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 时间

    private var clockCard: some View {
        Card(title: "时间",
             value: Format.clock(Date(), timeZone: .current),
             accent: .gray) {
            VStack(spacing: 4) {
                StatRow(label: "本地", value: Format.fullDateTime(Date()))
                ForEach(settings.clockZoneIdentifiers, id: \.self) { identifier in
                    if let zone = TimeZone(identifier: identifier) {
                        StatRow(label: Format.zoneLabel(identifier),
                                value: Format.clock(Date(), timeZone: zone))
                    }
                }
                if settings.clockZoneIdentifiers.isEmpty {
                    Text("可在「设置 › 常规 › 时钟」里添加其它时区")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - 进程

    private var processCard: some View {
        Card(title: "占用最高的进程", accent: .gray) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(ProcessSort.allCases) { sort in
                        Button(sort.title) {
                            settings.processSort = sort
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: settings.processSort == sort ? .semibold : .regular))
                        .foregroundColor(settings.processSort == sort ? .accentColor : .secondary)
                    }
                    Spacer()
                    Text("\(store.processes.count) 个采样")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                if store.processes.isEmpty {
                    Text("采样中…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.rankedProcesses(limit: settings.processCount)) { process in
                        HStack(spacing: 6) {
                            Text(process.name)
                                .font(.system(size: 10.5))
                                .foregroundColor(process.isSuspended ? .red : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if process.isSuspended {
                                Text("挂起")
                                    .font(.system(size: 8))
                                    .foregroundColor(.red)
                            }
                            Spacer(minLength: 4)
                            Text(String(format: "%.1f%%", process.cpu))
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundColor(process.cpu >= 50 ? .orange : .secondary)
                            Text(Format.bytes(process.memory))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 辅助

    /// 历史数据还没攒够时退回内存里的实时曲线
    private func chartValues(_ metric: HistoryMetric, fallback: [Double]) -> [Double] {
        guard settings.historyEnabled else { return fallback }
        let values = history.series(metric, range: range)
        return values.isEmpty ? fallback : values
    }
}
