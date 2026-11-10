import Foundation
import Combine

/// 采样调度中心。持有全部 Reader，按间隔统一刷新，刷新完通知界面。
/// 注意：所有 Reader 都是有状态的（要算两次采样的差值），首次采样只有基线，速率为 0。
///
/// 重活降频：SMC 每 2 拍、进程每 3 拍、Wi-Fi 每 5 拍，避免每秒都去 fork / 翻 IORegistry。
final class Sampler: ObservableObject {

    // 最新快照
    @Published private(set) var cpu = CPUSample()
    @Published private(set) var memory = MemorySample()
    @Published private(set) var network = NetworkSample()
    @Published private(set) var disk = DiskSample()
    @Published private(set) var battery: BatterySample?
    @Published private(set) var sensors = SensorSample()
    @Published private(set) var gpu = GPUSample()
    @Published private(set) var wifi = WiFiSample()
    @Published private(set) var processes: [ProcessSample] = []

    // 曲线历史（内存内，秒级；长周期走 HistoryStore）
    @Published private(set) var cpuHistory = History(capacity: 120)
    @Published private(set) var memoryHistory = History(capacity: 120)
    @Published private(set) var downHistory = History(capacity: 120)
    @Published private(set) var upHistory = History(capacity: 120)
    @Published private(set) var diskReadHistory = History(capacity: 120)
    @Published private(set) var diskWriteHistory = History(capacity: 120)
    @Published private(set) var gpuHistory = History(capacity: 120)
    @Published private(set) var temperatureHistory = History(capacity: 120)

    /// 每次刷新结束回调（状态栏据此重绘）
    var onUpdate: (() -> Void)?

    let alerts = AlertEngine()

    private let settings = Settings.shared

    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let networkReader = NetworkReader()
    private let diskReader = DiskReader()
    private let batteryReader = BatteryReader()
    private let processReader = ProcessReader()
    private let smcReader = SMCReader()
    private let gpuReader = GPUReader()
    private let wifiReader = WiFiReader()

    private var timer: Timer?
    private var lastTickDate = Date()
    private var tickCount = 0

    init() {
        // 先跑一次，把 CPU 各核 tick 基线打进去，避免第一秒显示 0%
        _ = cpuReader.sample()
        _ = networkReader.sample(interval: 1)
        _ = diskReader.sample(interval: 1)
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        stop()
        let interval = min(max(settings.refreshInterval, 1), 10)
        lastTickDate = Date()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        start()
    }

    @objc private func tick() {
        let now = Date()
        let elapsed = max(now.timeIntervalSince(lastTickDate), 0.2)
        lastTickDate = now
        tickCount += 1

        if let cpuSample = cpuReader.sample() {
            cpu = cpuSample
            cpuHistory.push(cpuSample.usage)
        }

        if let memorySample = memoryReader.sample() {
            memory = memorySample
            memoryHistory.push(memorySample.usage)
        }

        gpu = gpuReader.sample()
        gpuHistory.push(gpu.utilization)

        let networkSample = networkReader.sample(interval: elapsed, wifiInterface: wifiReader.interfaceName)
        network = networkSample
        downHistory.push(networkSample.downBytesPerSec)
        upHistory.push(networkSample.upBytesPerSec)

        let diskSample = diskReader.sample(interval: elapsed)
        disk = diskSample
        diskReadHistory.push(diskSample.readBytesPerSec)
        diskWriteHistory.push(diskSample.writeBytesPerSec)

        battery = batteryReader.sample()

        // SMC 走 IOKit，2 个 tick 采一次就够
        if tickCount % 2 == 1 {
            sensors = smcReader.sample()
            if let temperature = sensors.cpuTemperature {
                temperatureHistory.push(temperature)
            }
        }

        // Wi-Fi 详情变化慢，5 个 tick 一次
        if tickCount % 5 == 1 {
            wifi = wifiReader.sample()
        }

        // 进程列表要 fork 一个 ps，3 个 tick 采一次
        if tickCount % 3 == 1 {
            processes = processReader.sample()
        }

        // 历史落盘（内部到点才真正写文件）
        if settings.historyEnabled {
            HistoryStore.shared.record(cpu: cpu.usage,
                                       memory: memory.usage,
                                       gpu: gpu.available ? gpu.utilization : 0,
                                       netDown: network.downBytesPerSec,
                                       netUp: network.upBytesPerSec,
                                       diskRead: disk.readBytesPerSec,
                                       diskWrite: disk.writeBytesPerSec,
                                       temperature: sensors.cpuTemperature,
                                       battery: battery?.percent)
        }

        alerts.evaluate(values: alertValues(), rules: settings.alerts)

        onUpdate?()
    }

    // MARK: - 告警取值

    private func alertValues() -> [AlertMetric: Double] {
        var values: [AlertMetric: Double] = [
            .cpu: cpu.usage * 100,
            .memory: memory.usage * 100,
            .disk: disk.usage * 100,
            .networkDown: network.downBytesPerSec / 1_048_576
        ]
        if gpu.available {
            values[.gpu] = gpu.utilization * 100
        }
        if let temperature = sensors.cpuTemperature {
            values[.temperature] = temperature
        }
        if let battery {
            values[.batteryLow] = battery.percent
        }
        return values
    }

    // MARK: - 派生

    /// 按用户选择排序后的进程列表
    func rankedProcesses(limit: Int = 6) -> [ProcessSample] {
        let sorted: [ProcessSample]
        switch settings.processSort {
        case .cpu: sorted = processes.sorted { $0.cpu > $1.cpu }
        case .memory: sorted = processes.sorted { $0.memory > $1.memory }
        }
        return Array(sorted.prefix(limit))
    }
}
