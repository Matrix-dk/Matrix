import AppKit

/// 状态栏里的一段：图标 + 标签 + 数值 + 可选迷你曲线 / 可选圆环。
struct MenuBarSegment {
    var label: String = ""
    var value: String = ""
    var valueColor: NSColor = .labelColor
    var valueAlpha: CGFloat = 1
    var sparkline: [Double] = []
    var sparkColor: NSColor = .systemBlue
    var iconName: String? = nil
    var ringProgress: Double? = nil

    var isEmpty: Bool {
        label.isEmpty && value.isEmpty && iconName == nil && ringProgress == nil
    }
}

/// 用 Core Graphics 现画状态栏图片（非 template，才能保留颜色）。
enum MenuBarRenderer {

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    private static let sparkWidth: CGFloat = 24
    private static let sparkHeight: CGFloat = 12
    private static let segmentGap: CGFloat = 9
    private static let sparkGap: CGFloat = 3
    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 3
    private static let ringSize: CGFloat = 14
    private static let height: CGFloat = 18

    static var isDarkMenuBar: Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func image(for segments: [MenuBarSegment]) -> NSImage? {
        let visible = segments.filter { !$0.isEmpty }
        guard !visible.isEmpty else { return nil }

        let labelColor = isDarkMenuBar
            ? NSColor.white.withAlphaComponent(0.62)
            : NSColor.black.withAlphaComponent(0.58)

        var measured: [(segment: MenuBarSegment, label: NSAttributedString?, value: NSAttributedString?, symbol: NSImage?)] = []
        var totalWidth: CGFloat = 0

        for segment in visible {
            var labelString: NSAttributedString?
            var valueString: NSAttributedString?
            var symbol: NSImage?
            var width: CGFloat = 0

            if let iconName = segment.iconName {
                symbol = symbolImage(iconName, color: segment.valueColor)
                if symbol != nil {
                    width += iconSize
                    if !segment.value.isEmpty { width += iconGap }
                }
            }
            if let progress = segment.ringProgress {
                _ = progress
                width += ringSize
                if !segment.value.isEmpty { width += iconGap }
            }
            if !segment.label.isEmpty {
                let string = NSAttributedString(string: segment.label, attributes: [
                    .font: font,
                    .foregroundColor: labelColor
                ])
                labelString = string
                width += string.size().width
                if !segment.value.isEmpty { width += 3 }
            }
            if !segment.value.isEmpty {
                let string = NSAttributedString(string: segment.value, attributes: [
                    .font: font,
                    .foregroundColor: segment.valueColor.withAlphaComponent(segment.valueAlpha)
                ])
                valueString = string
                width += string.size().width
            }
            if segment.sparkline.count > 1 {
                width += sparkWidth + sparkGap
            }
            measured.append((segment, labelString, valueString, symbol))
            totalWidth += width
        }

        totalWidth += segmentGap * CGFloat(max(visible.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(totalWidth) + 2, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        var x: CGFloat = 1
        for item in measured {
            if let symbol = item.symbol {
                let rect = NSRect(x: x,
                                  y: (height - iconSize) / 2,
                                  width: iconSize,
                                  height: iconSize)
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                x += iconSize
                if item.value != nil { x += iconGap }
            }
            if let progress = item.segment.ringProgress {
                let rect = NSRect(x: x,
                                  y: (height - ringSize) / 2,
                                  width: ringSize,
                                  height: ringSize)
                drawRing(progress: progress, in: rect, color: item.segment.sparkColor)
                x += ringSize
                if item.value != nil { x += iconGap }
            }
            if item.segment.sparkline.count > 1 {
                let rect = NSRect(x: x,
                                  y: (height - sparkHeight) / 2,
                                  width: sparkWidth,
                                  height: sparkHeight)
                drawSparkline(item.segment.sparkline, in: rect, color: item.segment.sparkColor)
                x += sparkWidth + sparkGap
            }
            if let label = item.label {
                let size = label.size()
                label.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += size.width
                if item.value != nil { x += 3 }
            }
            if let value = item.value {
                let size = value.size()
                value.draw(at: NSPoint(x: x, y: (height - size.height) / 2))
                x += size.width
            }
            x += segmentGap
        }

        image.isTemplate = false
        return image
    }

    // MARK: - 绘制

    /// SF Symbol 着色：paletteColors 让图标直接按指定颜色出像素，
    /// 比「先画再 blend」稳，也不会在深色菜单栏上糊成一团。
    private static func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let size = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        return base.withSymbolConfiguration(size.applying(palette))
    }

    private static func drawRing(progress: Double, in rect: NSRect, color: NSColor) {
        let clamped = min(1, max(0, progress))
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.6

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        NSColor.gray.withAlphaComponent(0.32).setStroke()
        track.stroke()

        guard clamped > 0.005 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center,
                      radius: radius,
                      startAngle: 90,
                      endAngle: 90 - CGFloat(clamped) * 360,
                      clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private static func drawSparkline(_ values: [Double], in rect: NSRect, color: NSColor) {
        guard values.count > 1 else { return }
        let peak = max(values.max() ?? 0, 0.0001)

        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        let stepX = rect.width / CGFloat(values.count - 1)
        let usableHeight = rect.height - 2

        for (index, value) in values.enumerated() {
            let normalized = CGFloat(max(0, min(1, value / peak)))
            let point = NSPoint(x: rect.minX + CGFloat(index) * stepX,
                                y: rect.minY + 1 + normalized * usableHeight)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        color.withAlphaComponent(0.85).setStroke()
        path.stroke()
    }
}
