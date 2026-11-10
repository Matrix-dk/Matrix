import SwiftUI
import Foundation

// MARK: - 卡片容器

struct Card<Content: View>: View {
    let title: String
    let value: String
    var detail: String? = nil
    var accent: Color = .accentColor
    let content: () -> Content

    init(title: String,
         value: String = "",
         detail: String? = nil,
         accent: Color = .accentColor,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.value = value
        self.detail = detail
        self.accent = accent
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(value.isEmpty ? 0 : 1)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        )
    }
}

// MARK: - 迷你曲线

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var peak: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let points = makePoints(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(colors: [color.opacity(0.22), color.opacity(0.01)],
                                       startPoint: .top,
                                       endPoint: .bottom)
                    )

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func makePoints(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 1 else { return [] }
        let maximum = max(peak ?? values.max() ?? 1, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = CGFloat(max(0, min(1, value / maximum)))
            return CGPoint(x: CGFloat(index) * stepX,
                           y: size.height - 1 - normalized * (size.height - 2))
        }
    }
}

// MARK: - 长周期图表（带时间轴与峰值）

struct RangeChart: View {
    var values: [Double]
    var color: Color
    var range: TimeRange
    var ceiling: Double? = nil
    var formatter: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 44

    private var peak: Double {
        values.max() ?? 0
    }

    private var average: Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                gridLines

                if values.count > 1 {
                    Sparkline(values: values, color: color, peak: ceiling ?? max(peak, 0.0001))
                        .frame(height: height)
                } else {
                    Text("数据积累中…")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)

            HStack {
                Text(axisLabel(offsetFromNow: -range.seconds))
                Spacer()
                Text("峰 \(formatter(peak)) · 均 \(formatter(average))")
                    .foregroundColor(color.opacity(0.85))
                Spacer()
                Text("现在")
            }
            .font(.system(size: 8.5))
            .foregroundColor(.secondary)
        }
    }

    private var gridLines: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25)
            Spacer()
            Divider().opacity(0.25)
            Spacer()
            Divider().opacity(0.25)
        }
    }

    private func axisLabel(offsetFromNow: TimeInterval) -> String {
        let date = Date().addingTimeInterval(offsetFromNow)
        return range == .week ? Format.weekdayMark(date) : Format.hourMark(date)
    }
}

// MARK: - 占用条

struct UsageBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 每核竖条

struct CoreBars: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let count = max(values.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max((geometry.size.width - CGFloat(count - 1) * spacing) / CGFloat(count), 1.5)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Self.color(for: value))
                            .frame(height: max(1.5, CGFloat(min(value, 1)) * geometry.size.height))
                    }
                    .frame(width: barWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    static func color(for value: Double) -> Color {
        if value >= 0.85 { return .red }
        if value >= 0.6 { return .orange }
        return .green
    }
}

// MARK: - 键值行

struct StatRow: View {
    var label: String
    var value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundColor(color)
        }
    }
}

// MARK: - 信号强度

struct SignalBars: View {
    var level: Int          // 0...4
    var color: Color = .blue

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0 ..< 4, id: \.self) { index in
                let barHeight: CGFloat = 3.0 + Double(index) * 2.5
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < level ? color : Color.primary.opacity(0.15))
                    .frame(width: 2.5, height: barHeight)
            }
        }
        .frame(height: 12, alignment: .bottom)
    }
}

// MARK: - 小标签

struct Pill: View {
    var text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundColor(color)
    }
}

// MARK: - 用量色

enum UsageColor {
    static func of(_ fraction: Double) -> Color {
        if fraction >= 0.85 { return .red }
        if fraction >= 0.6 { return .orange }
        return .green
    }

    static func temperature(_ celsius: Double) -> Color {
        if celsius >= 90 { return .red }
        if celsius >= 75 { return .orange }
        return .primary
    }
}
