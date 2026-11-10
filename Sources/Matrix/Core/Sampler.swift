import Foundation
import Combine

/// 采样调度中心。持有全部 Reader，按间隔统一刷新，刷新完通知界面。
/// 注意：所有 Reader 都是有状态的（要算两次采样的差值），首次采样只有基线，速率为 0。
final class Sampler: ObservableObject {

    // 最新快照
    @Published private(set) var cpu = CPUSample()
    @Published private(set) var memory = MemorySample()
    @Published private(set) var network = NetworkSample()
    @Published private(set) var disk = DiskSample()
    @Published private(set) var battery: BatterySample?
    @Published private(set) var sensors = SensorSample()
    @Published private(set) var processes: [ProcessSample] = []

    // 曲线历史
    @Published private(set) var cpuHistory = History(capacity: 120)
    @Published private(set) var memoryHistory = History(capacity: 120)
    @Published private(set) var downHistory = History(capacity: 120)
    @Published private(set) var upHistory = History(capacity: 120)
    @Published private(set) var diskReadHistory = History(capacity: 120)
    @Published private(set) var diskWriteHistory = History(capacity: 120)

    /// 每次刷新结束回调（状态栏据此重绘）
    var onUpdate: (() -> Void)?

    private let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let networkReader = NetworkReader()
    private let diskReader = DiskReader()
    private let batteryReader = BatteryReader()
    private let processReader = ProcessReader()
    private let smcReader = SMCReader()

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
        let interval = min(max(Settings.shared.refreshInterval, 1), 10)
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

        let networkSample = networkReader.sample(interval: elapsed)
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
        }

        // 进程列表要 fork 一个 ps，3 个 tick 采一次
        if tickCount % 3 == 1 {
            processes = processReader.sample()
        }

        onUpdate?()
    }
}
