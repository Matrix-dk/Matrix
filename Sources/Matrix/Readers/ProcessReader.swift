import Foundation

/// 进程排行用 /bin/ps 拿结果。
///
/// 为什么不用 libproc：算真实 CPU% 需要自己按 pid 存两次 rusage 差值，
/// 而 ps 已经把这件事做完了，输出稳定、跨版本兼容，代价只是一次 fork（3 个采样周期一次）。
final class ProcessReader {

    func sample(limit: Int = 6) -> [ProcessSample] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,pcpu=,rss=,comm=", "-r"]

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

        var samples: [ProcessSample] = []
        for line in text.split(separator: "\n") {
            // 只切前 3 段，剩下的整体当进程路径，避免带空格的路径被切碎
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let residentKB = UInt64(parts[2]) else { continue }

            let name = (String(parts[3]) as NSString).lastPathComponent
            samples.append(ProcessSample(pid: pid,
                                         name: name,
                                         cpu: cpu,
                                         memory: residentKB * 1024))
            if samples.count >= limit { break }
        }
        return samples
    }
}
