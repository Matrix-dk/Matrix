import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var store: Sampler
    @ObservedObject var settings: Settings
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskCard
                    if let battery = store.battery {
                        batteryCard(battery)
                    }
                    sensorsCard
                    processCard
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .frame(width: 344, height: 566)
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
            Spacer()
            Text("已运行 " + Format.uptime(store.cpu.uptime))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onOpenSettings) {
                Label("设置", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            Spacer()

            Text("每 \(Int(settings.refreshInterval))s 刷新")
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)

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

    // MARK: - CPU

    private var cpuCard: some View {
        Card(title: "CPU",
             value: Format.percent(store.cpu.usage),
             detail: String(format: "1 分钟负载 %.2f", store.cpu.loadOne),
             accent: .orange) {
            VStack(spacing: 7) {
                Sparkline(values: store.cpuHistory.values, color: .orange, peak: 1)
                    .frame(height: 30)

                CoreBars(values: store.cpu.perCore)
                    .frame(height: 26)

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

    // MARK: - 内存

    private var memoryCard: some View {
        Card(title: "内存",
             value: Format.percent(store.memory.usage),
             detail: "\(Format.bytes(store.memory.used)) / \(Format.bytes(store.memory.total))",
             accent: .purple) {
            VStack(spacing: 7) {
                Sparkline(values: store.memoryHistory.values, color: .purple, peak: 1)
                    .frame(height: 26)

                UsageBar(fraction: store.memory.usage, color: .purple)

                VStack(spacing: 3) {
                    StatRow(label: "App 内存", value: Format.bytes(store.memory.app))
                    StatRow(label: "联动内存", value: Format.bytes(store.memory.wired))
                    StatRow(label: "已压缩", value: Format.bytes(store.memory.compressed))
                    StatRow(label: "文件缓存", value: Format.bytes(store.memory.cached))
                    StatRow(label: "交换空间",
                            value: store.memory.swapTotal > 0
                                ? "\(Format.bytes(store.memory.swapUsed)) / \(Format.bytes(store.memory.swapTotal))"
                                : "未使用")
                }
            }
        }
    }

    // MARK: - 网络

    private var networkCard: some View {
        Card(title: "网络",
             value: "↓ " + Format.rate(store.network.downBytesPerSec),
             detail: store.network.ipAddress.isEmpty ? nil : store.network.ipAddress,
             accent: .blue) {
            VStack(spacing: 7) {
                Sparkline(values: store.downHistory.values, color: .blue)
                    .frame(height: 26)

                StatRow(label: "下行", value: Format.rate(store.network.downBytesPerSec), color: .blue)
                StatRow(label: "上行", value: Format.rate(store.network.upBytesPerSec), color: .orange)
                StatRow(label: "本次开机累计",
                        value: "↓\(Format.bytes(store.network.totalDown))  ↑\(Format.bytes(store.network.totalUp))")

                if !store.network.interfaceName.isEmpty {
                    StatRow(label: "主接口", value: store.network.interfaceName)
                }
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
            }
        }
    }

    // MARK: - 传感器

    private var sensorsCard: some View {
        Card(title: "传感器",
             value: store.sensors.cpuTemperature.map { String(format: "%.1f°C", $0) } ?? "—",
             accent: .pink) {
            VStack(spacing: 4) {
                if let temperature = store.sensors.cpuTemperature {
                    StatRow(label: "CPU 温度",
                            value: String(format: "%.1f°C", temperature),
                            color: temperature >= 80 ? .red : .primary)
                }
                ForEach(Array(store.sensors.fanRPMs.enumerated()), id: \.offset) { index, rpm in
                    StatRow(label: "风扇 \(index)", value: String(format: "%.0f RPM", rpm))
                }
                if !store.sensors.smcAvailable {
                    Text("当前机型无法读取 SMC（Apple Silicon 部分机型温度 key 不同）")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 进程

    private var processCard: some View {
        Card(title: "占用最高的进程", accent: .gray) {
            VStack(spacing: 4) {
                if store.processes.isEmpty {
                    Text("采样中…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.processes) { process in
                        HStack(spacing: 6) {
                            Text(process.name)
                                .font(.system(size: 10.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
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
}
