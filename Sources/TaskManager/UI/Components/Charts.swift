import SwiftUI

struct ChartLine {
    var values: [Double]
    var dashed = false
    var filled = true
}

/// Windows 11 style performance graph: square grid, thin line, translucent fill,
/// newest sample on the right.
struct LineChart: View {
    var lines: [ChartLine]
    var color: Color
    /// Fixed scale (e.g. 100 for percentages). nil scales to the data.
    var maximum: Double?
    var gridColumns = 10
    var gridRows = 10
    var showsGrid = true
    var lineWidth: CGFloat = 1.2

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let scale = effectiveMaximum
            if showsGrid {
                var grid = Path()
                for i in 1..<gridColumns {
                    let x = rect.width * CGFloat(i) / CGFloat(gridColumns)
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: rect.height))
                }
                for i in 1..<gridRows {
                    let y = rect.height * CGFloat(i) / CGFloat(gridRows)
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: rect.width, y: y))
                }
                context.stroke(grid, with: .color(color.opacity(0.12)), lineWidth: 0.5)
            }
            for line in lines {
                guard line.values.count > 1 else { continue }
                let step = rect.width / CGFloat(line.values.count - 1)
                var path = Path()
                for (index, value) in line.values.enumerated() {
                    let ratio = scale > 0 ? CGFloat(min(value, scale) / scale) : 0
                    let point = CGPoint(x: CGFloat(index) * step, y: rect.height - ratio * rect.height)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                if line.filled {
                    var area = path
                    area.addLine(to: CGPoint(x: rect.width, y: rect.height))
                    area.addLine(to: CGPoint(x: 0, y: rect.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.14)))
                }
                let style = StrokeStyle(lineWidth: lineWidth, lineJoin: .round, dash: line.dashed ? [4, 3] : [])
                context.stroke(path, with: .color(color), style: style)
            }
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(color.opacity(0.55)), lineWidth: 1)
        }
    }

    var effectiveMaximum: Double {
        if let maximum { return maximum }
        let peak = lines.flatMap(\.values).max() ?? 0
        return ChartScale.niceCeiling(peak)
    }
}

enum ChartScale {
    /// Rounds a peak up to a readable axis maximum (1, 2, 5 × 10ⁿ).
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        for step in [1.0, 2.0, 5.0, 10.0] where value <= step * base {
            return step * base
        }
        return 10 * base
    }
}

/// Compact chart for the Performance sidebar and the CPU grid.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maximum: Double? = 100
    var secondary: [Double]?

    var body: some View {
        LineChart(
            lines: [ChartLine(values: values)] + (secondary.map { [ChartLine(values: $0, dashed: true, filled: false)] } ?? []),
            color: color,
            maximum: maximum,
            showsGrid: false,
            lineWidth: 1
        )
    }
}

/// Stacked bar showing how memory is used (App / Wired / Compressed / Cached / Free).
struct CompositionBar: View {
    struct Segment: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var opacity: Double
    }

    var segments: [Segment]
    var total: Double
    var color: Color

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    let width = total > 0 ? geometry.size.width * CGFloat(segment.value / total) : 0
                    Rectangle()
                        .fill(color.opacity(segment.opacity))
                        .frame(width: max(0, width))
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(color.opacity(0.6)).frame(width: 1)
                        }
                        .help("\(segment.label): \(Format.bytes(UInt64(segment.value)))")
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(Rectangle().strokeBorder(color.opacity(0.7), lineWidth: 1))
    }
}
