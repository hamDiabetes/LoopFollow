// LoopFollow
// WidgetChartView.swift

import Charts
import SwiftUI
import WidgetKit

/// Glucose scatter over the configured duration, drawn edge to edge as the
/// widget's backdrop.
///
/// Values stay in mg/dL until `display(_:)` converts them to the user's unit.
struct WidgetChartView: View {
    let series: GlucoseChartSeries
    let unit: GlucoseSnapshot.Unit
    let duration: WidgetChartDuration
    var style: WidgetChartStyle = .standard

    /// Bands at the base and the top of the widget that the caller draws its own
    /// text over. Nothing is plotted into them, so the threshold lines stay
    /// readable wherever the data happens to sit.
    var bottomReserve: CGFloat = 0
    var topReserve: CGFloat = 0

    /// Tinted and clear appearances flatten the plot to one colour, so the marks
    /// fall back to opacity for separation.
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// Headroom above and below the extremes, so points are not drawn on the edge.
    private static let paddingMgdl: Double = 22

    /// Extra headroom at the top, where the chart meets the widget's own edge.
    private static let topPaddingMgdl: Double = 24

    /// Narrowest Y domain, so flat data still reads as flat.
    private static let minSpanMgdl: Double = 120

    private var isFullColor: Bool {
        renderingMode == .fullColor
    }

    private var thresholds: (low: Double, high: Double) {
        LAAppGroupSettings.thresholdsMgdl()
    }

    /// Window drawn on the X axis.
    private var window: TimeInterval {
        duration.seconds
    }

    /// Keeps the first and last marks clear of the widget's rounded corners.
    private var edgeSlack: TimeInterval {
        window * 0.02
    }

    /// Dots have to shrink as the span grows or the long windows read as a band.
    private var symbolSize: Double {
        switch duration {
        case .oneHour, .threeHours, .sixHours: 16
        case .twelveHours: 12
        case .twentyFourHours: 9
        }
    }

    private var lineWidth: Double {
        switch duration {
        case .oneHour, .threeHours, .sixHours: 2.6
        case .twelveHours: 2.2
        case .twentyFourHours: 1.8
        }
    }

    /// Longer than this between two readings and the line is cut rather than
    /// carried across: a curve drawn through a sensor dropout is history that
    /// never happened. Three missed readings at the usual five minute cadence.
    private static let maxGap: TimeInterval = 20 * 60

    /// Every reading in the window is drawn. A day is a few hundred marks, well
    /// inside what the chart handles, and thinning a glucose chart risks losing
    /// the excursion that made it worth looking at.
    private var points: [GlucoseChartPoint] {
        let start = Date().addingTimeInterval(-window)
        let visible = series.points.filter { $0.date >= start }

        // Marks are identified by the whole point, so a reading posted twice
        // would collide and one of the two would go missing.
        var deduped: [GlucoseChartPoint] = []
        for point in visible where point != deduped.last {
            deduped.append(point)
        }
        return deduped
    }

    private func display(_ mgdl: Double) -> Double {
        switch unit {
        case .mgdl: return mgdl
        case .mmol: return GlucoseConversion.toMmol(mgdl)
        }
    }

    /// Follows the data but always contains both threshold lines, so nothing
    /// charted is ever clipped out of view.
    private func domainMgdl(for values: [Double], thresholds t: (low: Double, high: Double)) -> ClosedRange<Double> {
        // Settings import accepts the thresholds unvalidated, so order them here:
        // a range whose lower bound exceeds its upper one is a runtime trap.
        let low = min(t.low, t.high)
        let high = max(t.low, t.high)
        let lower = min(values.min() ?? low, low) - Self.paddingMgdl
        let upper = max(values.max() ?? high, high) + Self.topPaddingMgdl
        guard upper - lower < Self.minSpanMgdl else { return lower ... upper }

        let middle = (lower + upper) / 2
        return (middle - Self.minSpanMgdl / 2) ... (middle + Self.minSpanMgdl / 2)
    }

    /// Lifts the plotted range clear of the reserved bands: everything that has to
    /// be seen is squeezed into the height between them, while the scale itself
    /// still spans the whole view, so the chart keeps bleeding to all four edges.
    private func plotted(_ content: ClosedRange<Double>, height: CGFloat) -> ClosedRange<Double> {
        guard height > 0 else { return content }
        let below = Double(bottomReserve / height)
        let usable = 1 - below - Double(topReserve / height)
        guard usable > 0.3 else { return content }

        let span = (content.upperBound - content.lowerBound) / usable
        let lower = content.lowerBound - span * below
        return lower ... (lower + span)
    }

    /// Which threshold band a reading falls in, so a run of readings that share
    /// one can be drawn as a single line in a single colour.
    private func band(_ mgdl: Double, thresholds t: (low: Double, high: Double)) -> Int {
        if mgdl < t.low { return -1 } else if mgdl > t.high { return 1 } else { return 0 }
    }

    /// Splits the readings into stretches that can each be drawn as one line: a
    /// new run starts wherever the colour changes or the sensor stopped
    /// reporting. Runs that meet in time repeat the joining reading, so a change
    /// of colour leaves no hole in the trace, while a gap does.
    private func runs(_ visible: [GlucoseChartPoint], thresholds t: (low: Double, high: Double)) -> [[GlucoseChartPoint]] {
        var result: [[GlucoseChartPoint]] = []
        var current: [GlucoseChartPoint] = []

        for point in visible {
            guard let previous = current.last else {
                current = [point]
                continue
            }
            if point.date.timeIntervalSince(previous.date) > Self.maxGap {
                result.append(current)
                current = [point]
            } else if band(previous.value, thresholds: t) != band(point.value, thresholds: t) {
                current.append(point)
                result.append(current)
                current = [point]
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func color(forMgdl mgdl: Double, thresholds t: (low: Double, high: Double)) -> Color {
        if mgdl < t.low {
            return Color(.systemRed)
        } else if mgdl > t.high {
            return Color(.systemOrange)
        } else {
            return Color(.systemGreen)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            chart(height: proxy.size.height)
        }
    }

    private func chart(height: CGFloat) -> some View {
        let visible = points
        let t = thresholds

        let now = Date()
        let start = now.addingTimeInterval(-window - edgeSlack)
        let end = max(now, visible.last?.date ?? now).addingTimeInterval(edgeSlack)

        let content = domainMgdl(for: visible.map(\.value), thresholds: t)
        let domain = plotted(content, height: height)

        return Chart {
            RuleMark(y: .value("High", display(t.high)))
                .foregroundStyle(Color(.systemOrange).opacity(isFullColor ? 0.7 : 0.4))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("Low", display(t.low)))
                .foregroundStyle(Color(.systemRed).opacity(isFullColor ? 0.7 : 0.4))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            if style == .line {
                ForEach(Array(runs(visible, thresholds: t).enumerated()), id: \.offset) { index, run in
                    // A reading left alone by a gap on both sides has no line to
                    // be part of, so it is drawn as the point it is.
                    if run.count == 1, let point = run.first {
                        PointMark(
                            x: .value("Time", point.date),
                            y: .value("Glucose", display(point.value))
                        )
                        .symbolSize(symbolSize)
                        .foregroundStyle(color(forMgdl: point.value, thresholds: t).opacity(isFullColor ? 1 : 0.55))
                    } else {
                        ForEach(run, id: \.self) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Glucose", display(point.value)),
                                series: .value("Run", index)
                            )
                        }
                        // Monotone, not Catmull-Rom: a spline that overshoots
                        // would draw a dip below the low line that never
                        // happened. The colour comes from the run's own band.
                        .interpolationMethod(.monotone)
                        .lineStyle(.init(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color(forMgdl: run[0].value, thresholds: t).opacity(isFullColor ? 1 : 0.55))
                    }
                }
            } else {
                ForEach(visible, id: \.self) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Glucose", display(point.value))
                    )
                    .symbolSize(symbolSize)
                    .foregroundStyle(color(forMgdl: point.value, thresholds: t).opacity(isFullColor ? 1 : 0.55))
                }
            }
        }
        .chartXScale(domain: start ... end)
        .chartYScale(domain: display(domain.lowerBound) ... display(domain.upperBound))
        .chartXAxis {
            AxisMarks(position: .automatic) { _ in
                AxisGridLine(stroke: .init(lineWidth: 0.65, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(isFullColor ? 0.16 : 0.25))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { _ in
                AxisGridLine(stroke: .init(lineWidth: 0.65, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(isFullColor ? 0.16 : 0.25))
            }
        }
        .chartPlotStyle { $0.frame(maxWidth: .infinity, maxHeight: .infinity) }
        .overlay {
            if visible.isEmpty {
                // Centred in what the floating reading leaves free.
                Text("No recent glucose")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, 110)
            }
        }
    }
}

#Preview {
    let now = Date()
    let values: [Double] = [64, 72, 88, 104, 126, 149, 171, 188, 196, 184, 160, 138]
    let points = values.enumerated().map { index, value in
        GlucoseChartPoint(value: value, date: now.addingTimeInterval(Double(index - values.count) * 300))
    }

    return WidgetChartView(
        series: GlucoseChartSeries(points: points, updatedAt: now),
        unit: .mgdl,
        duration: .standard
    )
    .frame(height: 103)
}
