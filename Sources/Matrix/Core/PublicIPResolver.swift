import Foundation

/// 公网 IP 解析。
///
/// 默认**关闭**（要向第三方发请求，属于外发行为），用户在设置里显式开启才会跑。
/// 10 分钟最多查一次；失败静默——这个工具不该因为查 IP 失败弹错误框。
final class PublicIPResolver {

    private var cached = ""
    private var lastFetch = Date.distantPast
    private var inFlight = false

    var current: String { cached }

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastFetch) > 600, !inFlight else { return }
        guard let url = URL(string: "https://api.ipify.org?format=json") else { return }

        lastFetch = Date()
        inFlight = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            // 全部回主线程处理，避免 inFlight / cached 的读写竞争
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ip = object["ip"] as? String,
                      !ip.isEmpty else { return }
                self.cached = ip
            }
        }.resume()
    }

    /// 关掉公网 IP 功能时把缓存清掉，别留在界面上
    func clear() {
        cached = ""
    }
}
