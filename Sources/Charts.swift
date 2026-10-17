import SwiftUI
import Charts

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    let metric: Metric
    var id: String { name }
}

/// Ось значений: у всех рядов графика она одна, деления — всегда «круглые» числа.
enum ChartScale {
    case fixed(ClosedRange<Double>, ticks: [Double])
    case decimal(minimumTop: Double)   // от нуля до 1, 2 или 5 × 10ⁿ
    case binary(minimumTop: Double)    // байты: от нуля до степени двойки

    func resolve(top: Double) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        switch self {
        case .fixed(let range, let ticks):
            return (range, ticks)
        case .decimal(let minimum):
            let target = max(top * 1.1, minimum)
            let power = pow(10, floor(log10(target)))
            let mantissa = target / power
            let (lead, parts): (Double, Int) = mantissa <= 1 ? (1, 5) : mantissa <= 2 ? (2, 4) : mantissa <= 5 ? (5, 5) : (10, 5)
            let upper = lead * power
            return (0...upper, (0...parts).map { upper * Double($0) / Double(parts) })
        case .binary(let minimum):
            var upper = minimum
            while upper < top * 1.1 { upper *= 2 }
            return (0...upper, (0...4).map { upper * Double($0) / 4 })
        }
    }
}

/// График истории: линии 2 pt, перекрестие под курсором, значения под курсором — в шапке.
struct HistoryChart: View {
    let title: String
    let points: [HistoryPoint]
    let series: [ChartSeries]
    let window: ClosedRange<Date>
    let scale: ChartScale
    let format: (Double) -> String
    var height: CGFloat = 150

    @Local private var hover: Date? = nil

    private var hovered: HistoryPoint? {
        guard let hover else { return nil }
        return points.min { abs($0.t.timeIntervalSince(hover)) < abs($1.t.timeIntervalSince(hover)) }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                header
                chart.frame(height: height)
            }
        }
    }

    private var header: some View {
        let shown = hovered ?? points.last
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            CardTitle(title)
            if let h = hovered {
                Text(h.t, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(Palette.muted).monospacedDigit()
            }
            Spacer(minLength: 8)
            if series.count == 1, let only = series.first {
                Text(shown.flatMap { $0[only.metric] }.map(format) ?? "—")
                    .font(.callout).foregroundStyle(Palette.ink).monospacedDigit()
            } else {
                ForEach(series) { s in
                    LegendKey(color: s.color, name: s.name, value: shown.flatMap { $0[s.metric] }.map(format) ?? "—")
                }
            }
        }
    }

    private var chart: some View {
        let top = points.flatMap { p in series.compactMap { p[$0.metric] } }.max() ?? 0
        let axis = scale.resolve(top: top)
        return Chart {
            if series.count == 1, let only = series.first {
                ForEach(points) { p in
                    if let v = p[only.metric] {
                        AreaMark(x: .value("Время", p.t), y: .value(only.name, v))
                            .foregroundStyle(only.color.opacity(0.10))
                    }
                }
            }
            ForEach(series) { s in
                ForEach(points) { p in
                    if let v = p[s.metric] {
                        LineMark(x: .value("Время", p.t), y: .value(s.name, v), series: .value("Ряд", s.name))
                            .foregroundStyle(s.color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            if let h = hovered {
                RuleMark(x: .value("Время", h.t))
                    .foregroundStyle(Palette.axis)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series) { s in
                    if let v = h[s.metric] {
                        PointMark(x: .value("Время", h.t), y: .value(s.name, v))
                            .foregroundStyle(Palette.card)
                            .symbolSize(140)
                        PointMark(x: .value("Время", h.t), y: .value(s.name, v))
                            .foregroundStyle(s.color)
                            .symbolSize(64)
                    }
                }
            }
        }
        .chartXSelection(value: $hover)
        .chartXScale(domain: window)
        .chartYScale(domain: axis.domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.grid)
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .foregroundStyle(Palette.muted)
            }
        }
        .chartYAxis {
            AxisMarks(values: axis.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(format(v)).foregroundStyle(Palette.muted).monospacedDigit()
                    }
                }
            }
        }
    }
}
