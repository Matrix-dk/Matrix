import Foundation

/// 单条历史记录。字段用短名，因为这是按行落盘的 JSON，行数会到万级。
struct HistoryPoint: Codable {
    var t: Double = 0            // epoch 秒
    var cpu: Double = 0
    var mem: Double = 0
    var gpu: Double = 0
    var netIn: Double = 0
    var netOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var temp: Double = -1        // -1 表示没这项数据（台式机/读不到 SMC）
    var battery: Double = -1
}

extension HistoryMetric {
    func value(in point: HistoryPoint) -> Double {
        switch self {
        case .cpu: return point.cpu
        case .memory: return point.mem
        case .gpu: return point.gpu
        case .netDown: return point.netIn
        case .netUp: return point.netOut
        case .diskRead: return point.diskRead
        case .diskWrite: return point.diskWrite
        case .temperature: return point.temp
        case .battery: return point.battery
        }
    }
}

/// 历史数据。
///
/// 两层粒度：内存里保留最近 2 小时的**秒级**点（1h 视图靠它才够细），
/// 同时维护 7 天的**分钟级**点；分钟点按行追加到
/// `~/Library/Application Support/Matrix/history/YYYY-MM-DD.jsonl`，
/// 启动时回读最近 7 天。所以 24h / 7d 视图重启后依然在，1h 视图重启后
/// 先按分钟粒度显示，跑几分钟自动变细。
final class HistoryStore {

    static let shared = HistoryStore()

    private let maxRecentCount = 7200          // 2 小时 × 每秒 1 点
    private let maxMinuteCount = 60 * 24 * 7   // 7 天
    private let retentionDays = 7

    private var recent: [HistoryPoint] = []
    private var minutes: [HistoryPoint] = []
    private var lastWrittenT: Double = 0
    private var lastFlush = Date()
    private var loaded = false

    private let directory: URL
    private let ioQueue = DispatchQueue(label: "io.github.matrix.history", qos: .utility)
    private let lineEncoder = JSONEncoder()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Matrix/history", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lineEncoder.outputFormatting = []
        load()
    }

    // MARK: - 写入

    func record(cpu: Double,
                memory: Double,
                gpu: Double,
                netDown: Double,
                netUp: Double,
                diskRead: Double,
                diskWrite: Double,
                temperature: Double?,
                battery: Double?) {

        let now = Date()
        var point = HistoryPoint()
        point.t = now.timeIntervalSince1970
        point.cpu = cpu
        point.mem = memory
        point.gpu = gpu
        point.netIn = netDown
        point.netOut = netUp
        point.diskRead = diskRead
        point.diskWrite = diskWrite
        point.temp = temperature ?? -1
        point.battery = battery ?? -1

        recent.append(point)
        if recent.count > maxRecentCount {
            recent.removeFirst(recent.count - maxRecentCount)
        }

        // 分钟桶：同一分钟内的多次采样覆盖同一条，取最后一次
        let minuteStart = (point.t / 60).rounded(.down) * 60
        var bucket = point
        bucket.t = minuteStart
        if let last = minutes.last, last.t == minuteStart {
            minutes[minutes.count - 1] = bucket
        } else {
            minutes.append(bucket)
            if minutes.count > maxMinuteCount {
                minutes.removeFirst(minutes.count - maxMinuteCount)
            }
        }

        if now.timeIntervalSince(lastFlush) >= 60 {
            flush()
        }
    }

    /// 把已经结束的分钟点补写到磁盘。只写 t 大于上次落盘位置的部分，避免重复。
    func flush() {
        lastFlush = Date()
        let currentMinute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        let pending = minutes.filter { $0.t > lastWrittenT && $0.t < currentMinute }
        guard !pending.isEmpty else { return }
        lastWrittenT = pending.last?.t ?? lastWrittenT

        let url = fileURL(for: Date(timeIntervalSince1970: pending.last?.t ?? Date().timeIntervalSince1970))
        let encoder = lineEncoder
        ioQueue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else {
                // 文件不存在就走新建
                var blob = Data()
                for point in pending {
                    if let line = try? encoder.encode(point) {
                        blob.append(line)
                        blob.append(0x0A)
                    }
                }
                try? blob.write(to: url, options: .atomic)
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            var blob = Data()
            for point in pending {
                if let line = try? encoder.encode(point) {
                    blob.append(line)
                    blob.append(0x0A)
                }
            }
            try? handle.write(contentsOf: blob)
        }
    }

    // MARK: - 读取

    private func load() {
        guard !loaded else { return }
        loaded = true

        let decoder = JSONDecoder()
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: keys)
        else { return }

        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var merged: [Double: HistoryPoint] = [:]

        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date.distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard let point = try? decoder.decode(HistoryPoint.self, from: Data(line)) else { continue }
                // 同一分钟可能被追加过两次（比如跨进程/异常退出），后写的覆盖先写的
                merged[point.t] = point
            }
        }

        minutes = merged.values.sorted { $0.t < $1.t }
        if minutes.count > maxMinuteCount {
            minutes.removeFirst(minutes.count - maxMinuteCount)
        }
        lastWrittenT = minutes.last?.t ?? 0

        // 用最近 2 小时的分钟点给 recent 打底，1h 视图启动时就有东西可看
        let recentCutoff = Date().timeIntervalSince1970 - Double(maxRecentCount)
        recent = minutes.filter { $0.t >= recentCutoff }
    }

    var totalRecordedCount: Int { minutes.count }

    var earliestDate: Date? {
        minutes.first.map { Date(timeIntervalSince1970: $0.t) }
    }

    var storageDescription: String {
        directory.path
    }

    /// 清空内存与磁盘上的全部历史
    func clearAll() {
        recent.removeAll()
        minutes.removeAll()
        lastWrittenT = 0
        seriesCache.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 取序列

    /// 7 天窗口要遍历上万条点，SwiftUI 一次 body 可能算好几遍，
    /// 所以按「指标 + 范围 + 30 秒时间片」做一层记忆化。
    private var seriesCache: [String: (stamp: Double, values: [Double])] = [:]

    /// 取某个指标在指定时间范围内的曲线。
    /// 返回的数组长度最多是 `range.bucketCount`，前导无数据的桶会被裁掉，
    /// 避免曲线左端出现一段假的平线。
    func series(_ metric: HistoryMetric, range: TimeRange) -> [Double] {
        // 1 小时视图跟着采样走，长周期 30 秒刷一次就够
        let window: TimeInterval = range == .hour ? 2 : 30
        let stamp = (Date().timeIntervalSince1970 / window).rounded(.down) * window
        let cacheKey = "\(metric.rawValue)|\(range.rawValue)"
        if let entry = seriesCache[cacheKey], entry.stamp == stamp {
            return entry.values
        }
        let values = computeSeries(metric, range: range)
        seriesCache[cacheKey] = (stamp, values)
        return values
    }

    private func computeSeries(_ metric: HistoryMetric, range: TimeRange) -> [Double] {
        let now = Date().timeIntervalSince1970
        let start = now - range.seconds
        let buckets = range.bucketCount
        let width = range.seconds / Double(buckets)

        // 1 小时看秒级点才够细，其余看分钟点
        let source = range == .hour
            ? recent.filter { $0.t >= start }
            : minutes.filter { $0.t >= start }
        guard !source.isEmpty else { return [] }

        var sums = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)

        for point in source {
            let value = metric.value(in: point)
            if value < 0 { continue }
            let index = min(buckets - 1, max(0, Int((point.t - start) / width)))
            sums[index] += value
            counts[index] += 1
        }

        guard let firstFilled = counts.firstIndex(where: { $0 > 0 }) else { return [] }

        var result = [Double](repeating: 0, count: buckets)
        for index in 0 ..< buckets where counts[index] > 0 {
            result[index] = sums[index] / Double(counts[index])
        }
        // 空洞前向填充，避免曲线掉到 0
        var last = result[firstFilled]
        for index in firstFilled ..< buckets {
            if counts[index] > 0 { last = result[index] } else { result[index] = last }
        }

        return Array(result[firstFilled...])
    }

    // MARK: - 文件

    private func fileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return directory.appendingPathComponent(formatter.string(from: date) + ".jsonl")
    }
}
