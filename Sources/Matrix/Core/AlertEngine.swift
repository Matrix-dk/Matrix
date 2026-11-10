import Foundation
import Combine
import UserNotifications

/// 阈值告警。
///
/// 两个容易踩的坑都在这里挡掉了：
/// 1. `UNUserNotificationCenter.current()` 在**没有 bundle identifier** 的进程里会直接抛异常崩掉。
///    用 `swift run` 跑的时候 Bundle.main 没有 id，所以必须先判断再取。
/// 2. 规则抖动：只用「瞬时值超过阈值」会疯狂误报，所以要求**持续 N 秒**才触发，
///    触发后进冷却期。
final class AlertEngine: ObservableObject {

    private var pendingSince: [UUID: Date] = [:]
    private var lastFired: [UUID: Date] = [:]

    @Published private(set) var recentEvents: [AlertEvent] = []
    @Published private(set) var notificationsAuthorized = false
    private(set) var notificationsAvailable = false

    private var center: UNUserNotificationCenter?

    init() {
        // 没有 bundle id 就彻底不碰 UNUserNotificationCenter
        if Bundle.main.bundleIdentifier != nil {
            notificationsAvailable = true
            center = UNUserNotificationCenter.current()
            requestAuthorization()
        }
    }

    private func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationsAuthorized = granted
            }
        }
    }

    /// `values` 里没有的指标视为「当前不适用」（比如台式机没有电池），对应的待触发状态会被清掉。
    func evaluate(values: [AlertMetric: Double], rules: [AlertRule], now: Date = Date()) {
        for rule in rules where rule.enabled {
            guard let value = values[rule.metric] else {
                pendingSince[rule.id] = nil
                continue
            }

            let breached: Bool
            switch rule.comparison {
            case .above: breached = value > rule.threshold
            case .below: breached = value < rule.threshold
            }

            guard breached else {
                pendingSince[rule.id] = nil
                continue
            }

            guard let since = pendingSince[rule.id] else {
                pendingSince[rule.id] = now
                continue
            }

            guard now.timeIntervalSince(since) >= rule.sustainedSeconds else { continue }

            if let last = lastFired[rule.id],
               now.timeIntervalSince(last) < rule.cooldownMinutes * 60 {
                continue
            }
            lastFired[rule.id] = now
            fire(rule, value: value)
        }
    }

    private func fire(_ rule: AlertRule, value: Double) {
        let unit = rule.metric.unit
        let formatted = rule.metric == .networkDown
            ? String(format: "%.1f%@", value, unit)
            : String(format: "%.0f%@", value, unit)

        let comparisonText = rule.comparison == .above ? "高于" : "低于"
        let title = "Matrix · \(rule.metric.title)告警"
        let body = "当前 \(formatted)，已\(comparisonText)阈值 \(rule.thresholdText)\(unit) 并持续 \(Int(rule.sustainedSeconds)) 秒。"

        let event = AlertEvent(title: title, body: body, metric: rule.metric)
        recentEvents.insert(event, at: 0)
        if recentEvents.count > 20 {
            recentEvents.removeLast(recentEvents.count - 20)
        }

        guard let center, notificationsAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: rule.id.uuidString + "-\(Int(Date().timeIntervalSince1970))",
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    func clearHistory() {
        recentEvents.removeAll()
        lastFired.removeAll()
        pendingSince.removeAll()
    }
}

private extension AlertRule {
    var thresholdText: String {
        threshold == threshold.rounded()
            ? String(format: "%.0f", threshold)
            : String(format: "%.1f", threshold)
    }
}
