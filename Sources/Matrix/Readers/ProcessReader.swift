import Foundation

/// 进程排行用 /bin/ps 拿结果。
///
/// 为什么不用 libproc：算真实 CPU% 需要自己按 pid 存两次 rusage 差值，
/// 而 ps 已经把这件事做完了，输出稳定、跨版本兼容，代价只是一次 fork（3 个采样周期一次）。
///
/// 一次取「CPU 前 N + 内存前 M」的并集，界面上切换排序就不用重新 fork。
final class ProcessReader {

    func sample(cpuLimit: Int = 18, memoryLimit: Int = 12) -> [ProcessSample] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,pcpu=,rss=,state=,comm="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var all: [ProcessSample] = []
        for line in text.split(separator: "\n") {
            // 只切前 4 段，剩下的整体当进程路径，避免带空格的路径被切碎
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let residentKB = UInt64(parts[2]) else { continue }

            let state = String(parts[3])
            let path = String(parts[4])
            var name = (path as NSString).lastPathComponent
            if name.isEmpty { name = path }
            // 内核线程路径长这样：/usr/libexec/... 之类，取不到名字就跳过
            guard !name.isEmpty else { continue }

            all.append(ProcessSample(pid: pid,
                                     name: name,
                                     cpu: cpu,
                                     memory: residentKB * 1024,
                                     state: state))
        }

        var merged: [Int32: ProcessSample] = [:]
        for item in all.sorted(by: { $0.cpu > $1.cpu }).prefix(cpuLimit) {
            merged[item.pid] = item
        }
        for item in all.sorted(by: { $0.memory > $1.memory }).prefix(memoryLimit) {
            merged[item.pid] = item
        }
        return Array(merged.values)
    }
}
