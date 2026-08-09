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

    /// The loop's last published forecast, drawn as the spread across the curves
    /// it published. Nil, or a horizon of never, and none is drawn.
    var prediction: GlucosePrediction?
    var horizon: WidgetPredictionHorizon = .standard

    /// The moment this render is for, which is the entry's own date and not
    /// `Date()`. WidgetKit draws a run of pre-built entries at advancing dates
    /// without asking for a new timeline, so a window measured from the archive
    /// time freezes while those entries play out: the readings would sit still
    /// underneath an age line that goes on counting. Taking it from the entry
    /// walks the window forward one entry at a time, which is also what carries
    /// the now line into the forecast.
    let now: Date

    /// Bands at the base and the top of the widget that the caller draws its own
    /// text over. Nothing is plotted into them, so the threshold lines stay
    /// readable wherever the data happens to sit.
    var bottomReserve: CGFloat = 0
    var topReserve: CGFloat = 0

    /// Set by the Live Activity, which draws over a background tinted green,
    /// orange or red by the reading. The forecast is a translucent blue, which
    /// separates well from the widget's neutral panel and barely at all from a
    /// saturated tint — so on one it is given an outline and more weight.
    var onTintedBackground: Bool = false

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

    /// Keeps a mark clear of the widget's rounded corners. The leading edge
    /// always spends it, since the oldest reading runs straight into it. What
    /// the trailing edge does depends on what is standing there.
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

    /// The divider between what happened and what is only predicted. It has to
    /// be found at a glance and then stop being interesting, so it is faded at
    /// both ends and carries its weight across the middle, where the trace it
    /// separates actually sits. A rule of one flat opacity read as a hard edge
    /// cutting the card in two.
    private var nowRuleStyle: LinearGradient {
        let strong = isFullColor ? 0.38 : 0.48
        let weak = strong * 0.15
        return LinearGradient(
            stops: [
                .init(color: Color.primary.opacity(weak), location: 0),
                .init(color: Color.primary.opacity(strong), location: 0.34),
                .init(color: Color.primary.opacity(strong), location: 0.66),
                .init(color: Color.primary.opacity(weak), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Longer than this between two readings and the line is cut rather than
    /// carried across: a curve drawn through a sensor dropout is history that
    /// never happened. Three missed readings at the usual five minute cadence.
    private static let maxGap: TimeInterval = 20 * 60

    /// Compared with `>=` rather than `>` on purpose. The Live Activity's series
    /// arrives quantised to a five minute grid, so a real outage of twenty and a
    /// half minutes reconstructs as exactly twenty and used to be drawn straight
    /// through. Erring the other way can show a gap for an outage a little under
    /// twenty; an absence that overstates itself is a smaller lie than a line
    /// through readings nobody took.
    private static func isGap(_ interval: TimeInterval) -> Bool {
        interval >= maxGap
    }

    /// Every reading in the window is drawn. A day is a few hundred marks, well
    /// inside what the chart handles, and thinning a glucose chart risks losing
    /// the excursion that made it worth looking at.
    private var points: [GlucoseChartPoint] {
        let start = now.addingTimeInterval(-window)
        let visible = series.points.filter { $0.date >= start }

        // Marks are identified by the whole point, so a reading posted twice
        // would collide and one of the two would go missing.
        var deduped: [GlucoseChartPoint] = []
        for point in visible where point != deduped.last {
            deduped.append(point)
        }
        return deduped
    }

    /// The readings drawn, which is one more than the readings in the window.
    ///
    /// The scale starts a little before the window so the trace is not drawn on
    /// the very edge, and nothing was ever plotted in that margin — so the line
    /// began at the oldest reading inside the window and left a gap of up to one
    /// reading interval before the edge. Carrying the reading immediately before
    /// the window lets the line enter from off screen, where the chart clips it.
    ///
    /// Kept separate from `points` because the scale is derived from what is
    /// visible: an excursion just off the left edge must not open the Y axis for
    /// a reading nobody can see.
    private var drawnPoints: [GlucoseChartPoint] {
        let visible = points
        guard let first = visible.first,
              let anchor = series.points.last(where: { $0.date < first.date })
        else { return visible }
        return [anchor] + visible
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
            if Self.isGap(point.date.timeIntervalSince(previous.date)) {
                result.append(current)
                current = [point]
            } else if band(previous.value, thresholds: t) != band(point.value, thresholds: t) {
                // Both runs meet on the threshold itself rather than on the
                // first reading past it. Sharing the reading let a run keep its
                // colour a whole segment into the next band, so a trace on its
                // way up stayed green until it was already high — which reads
                // as in range for five minutes it was not. The area style has
                // always done this; the line style had not.
                let joint = crossing(from: previous, to: point, thresholds: t)
                current.append(joint)
                result.append(current)
                current = [joint, point]
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A run's own band, taken from the reading furthest inside it.
    ///
    /// Runs now begin and end on the threshold crossings, and a crossing sits
    /// exactly on a threshold — which `band` reads as in range, whichever side
    /// the run is actually on. Measuring from the extreme picks a real reading
    /// whenever the run has one, so a two-reading excursion is still coloured by
    /// the excursion rather than by the line it crossed to get there.
    private func runBand(_ run: [GlucoseChartPoint], thresholds t: (low: Double, high: Double)) -> Int {
        let distance = { (p: GlucoseChartPoint) in min(abs(p.value - t.low), abs(p.value - t.high)) }
        let anchor = run.max { distance($0) < distance($1) } ?? run[0]
        return band(anchor.value, thresholds: t)
    }

    private func color(forBand band: Int) -> Color {
        if band < 0 {
            return Color(.systemRed)
        } else if band > 0 {
            return Color(.systemOrange)
        } else {
            return Color(.systemGreen)
        }
    }

    private func color(forMgdl mgdl: Double, thresholds t: (low: Double, high: Double)) -> Color {
        color(forBand: band(mgdl, thresholds: t))
    }

    /// The threshold a band's fill is measured against. Above range that is the
    /// high line, so the fill stops there rather than carrying on through the
    /// in-range band; everywhere else it is the low line. In range the fill
    /// therefore hangs below the trace, and below range it stands above it,
    /// where a reading near the floor of the chart still has room to be seen.
    private func baseline(forBand band: Int, thresholds t: (low: Double, high: Double)) -> Double {
        band > 0 ? t.high : t.low
    }

    /// Where the trace passes a threshold between two readings that sit in
    /// different bands, by linear interpolation. Anchoring both fills there
    /// keeps one band's colour out of the next one's segment.
    private func crossing(
        from previous: GlucoseChartPoint,
        to next: GlucoseChartPoint,
        thresholds t: (low: Double, high: Double)
    ) -> GlucoseChartPoint {
        let from = band(previous.value, thresholds: t)
        let rising = next.value > previous.value
        let level = rising ? (from < 0 ? t.low : t.high) : (from > 0 ? t.high : t.low)
        let span = next.value - previous.value
        // Clamped, so a misordered threshold pair cannot put the crossing
        // outside the pair of readings it is meant to sit between.
        let fraction = span == 0 ? 0 : min(max((level - previous.value) / span, 0), 1)
        return GlucoseChartPoint(
            value: previous.value + span * fraction,
            date: previous.date.addingTimeInterval(next.date.timeIntervalSince(previous.date) * fraction)
        )
    }

    /// The line style's runs, with the reading two of them share replaced by
    /// the point where the trace crosses between their bands. Both fills then
    /// meet on the rule mark, instead of one band's colour reaching a segment
    /// into the next. Runs the gap rule separated stay apart, so no fill is
    /// drawn across a sensor dropout.
    private func areaRuns(
        _ visible: [GlucoseChartPoint],
        thresholds t: (low: Double, high: Double)
    ) -> [(band: Int, points: [GlucoseChartPoint])] {
        var result: [(band: Int, points: [GlucoseChartPoint])] = []
        var pending: GlucoseChartPoint?

        for run in runs(visible, thresholds: t) {
            guard !run.isEmpty else { continue }
            // Not the first reading: runs begin on a threshold crossing, and a
            // value sitting exactly on a threshold reads as in range whichever
            // side the run is really on.
            let band = runBand(run, thresholds: t)

            var points = run
            if let joint = pending { points.insert(joint, at: 0) }
            pending = nil

            if points.count > 1, let tail = points.last, self.band(tail.value, thresholds: t) != band {
                let point = crossing(from: points[points.count - 2], to: tail, thresholds: t)
                points[points.count - 1] = point
                pending = point
            }

            // Marks are identified by the whole point, so a crossing landing on
            // the reading it was derived from would collide with it.
            var deduped: [GlucoseChartPoint] = []
            for point in points where point != deduped.last {
                deduped.append(point)
            }
            if deduped.count > 1 { result.append((band, deduped)) }
        }
        return result
    }

    /// The band's colour, fading away from the trace toward the threshold it is
    /// measured against, so the fill carries some depth without competing with
    /// the line. A run below range is filled upward, so its gradient runs the
    /// other way.
    private func fill(forBand band: Int) -> LinearGradient {
        let base = color(forBand: band)
        guard isFullColor else {
            return LinearGradient(colors: [base.opacity(0.2)], startPoint: .top, endPoint: .bottom)
        }
        let stops = band < 0
            ? [base.opacity(0.14), base.opacity(0.5)]
            : [base.opacity(0.5), base.opacity(0.14)]
        return LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }

    @ChartContentBuilder
    private func areaMarks(_ visible: [GlucoseChartPoint], thresholds t: (low: Double, high: Double)) -> some ChartContent {
        ForEach(Array(areaRuns(visible, thresholds: t).enumerated()), id: \.offset) { index, run in
            ForEach(run.points, id: \.self) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Threshold", display(baseline(forBand: run.band, thresholds: t))),
                    yEnd: .value("Glucose", display(point.value)),
                    series: .value("Area", index)
                )
            }
            // Monotone for the same reason as the line: an overshooting spline
            // would fill a dip below the low line that never happened.
            .interpolationMethod(.monotone)
            .foregroundStyle(fill(forBand: run.band))
        }
    }

    // MARK: - Forecast

    /// Clock disagreement small enough to be ordinary drift. Past it the
    /// forecast cannot be placed against the readings at all, so none is drawn.
    private static let anchorSkewTolerance: TimeInterval = 60

    /// How much of the plot the forecast is allowed to claim. History is what
    /// actually happened and stays the larger half of the chart, so an hour
    /// picked against an hour of history draws thirty minutes. Applied quietly:
    /// the menu cannot make one choice depend on another, and the alternative is
    /// a grid of durations crossed with horizons.
    private var effectiveForecast: TimeInterval {
        min(horizon.seconds, window / 2)
    }

    /// The envelope this render draws, or empty when there is none to draw.
    ///
    /// Measured forward from the loop cycle the forecast was computed on, never
    /// from the moment being drawn. An hour means an hour past that cycle, so as
    /// the entries advance the now line walks into a forecast that stays where
    /// it was put and the part still ahead of us shrinks. Taking it forward from
    /// the render instead would keep refilling the hour out of a curve computed
    /// long before, which is a stale forecast dressed as a current one.
    ///
    /// Once nothing is left ahead of the now line there is no forecast at all
    /// and it goes. Age is structural here: it is watched running out rather
    /// than described in a label.
    private var bands: [GlucosePredictionBand] {
        guard effectiveForecast > 0, let prediction else { return [] }
        guard prediction.anchor.timeIntervalSince(now) <= Self.anchorSkewTolerance else { return [] }

        let drawn = prediction.bands(upTo: prediction.anchor.addingTimeInterval(effectiveForecast))
        guard let last = drawn.last, last.date > now else { return [] }
        return drawn
    }

    /// One flat colour, never the red and orange and green the readings use.
    /// That vocabulary says where the child is, and spending it on model output
    /// is what would let a forecast be read as a measurement.
    private var coneColor: Color {
        Color(.systemBlue)
    }

    /// Series identity is the plotted value rather than its label, so a
    /// forecast numbered from zero merges into the run of readings numbered
    /// from zero and drags the fill back across the whole of the history. The
    /// readings' runs are indexed upward, so the forecast sits below them.
    private static let coneSeries = -1

    /// A forecast with no width has nothing to fill, so it is drawn as a line.
    /// Loop publishes one curve and always lands here; oref does whenever it
    /// publishes one, which happens.
    private func isFlat(_ bands: [GlucosePredictionBand]) -> Bool {
        bands.allSatisfy { $0.high - $0.low < 0.5 }
    }

    /// Fades along the forecast, so how far from the reading it was computed
    /// from is legible without a number, and so the far end never looks as
    /// solid as the near one. One ramp across the whole envelope rather than a
    /// step per sample: the gradient is laid over the marks' own bounds, which
    /// are the cone's, and a per-sample opacity banded visibly at this size.
    private func coneFill(strong: Bool) -> LinearGradient {
        let near = isFullColor ? 0.40 : 0.26
        let far = isFullColor ? 0.09 : 0.07
        // A translucent fill is read against whatever is behind it, and on the
        // Live Activity that is a saturated tint rather than a neutral panel.
        let scale = (strong ? 1.8 : 1.0) * (onTintedBackground ? 1.45 : 1.0)
        return LinearGradient(
            colors: [coneColor.opacity(min(near * scale, 1)), coneColor.opacity(min(far * scale, 1))],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// The cone's edges, which is what survives being narrow.
    ///
    /// A fill needs area to be seen and the envelope is often a few points wide;
    /// an outline is legible at any width and against any of the three tints,
    /// because it separates by lightness rather than by hue. Deliberately not
    /// white: that is the reading's colour on this card, and the forecast does
    /// not get to borrow it any more than it gets to borrow red and green.
    private func coneEdge(strong: Bool) -> LinearGradient {
        let near = onTintedBackground ? (strong ? 0.95 : 0.80) : (strong ? 0.75 : 0.55)
        let far = onTintedBackground ? 0.30 : 0.20
        return LinearGradient(
            colors: [coneColor.opacity(near), coneColor.opacity(far)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Never any point marks, in any style. Dots are readings, and the forecast
    /// does not get to borrow them. The flat case is dashed for the same reason:
    /// the measured trace is solid, so the two cannot be read as one another.
    @ChartContentBuilder
    private func coneMarks(_ bands: [GlucosePredictionBand]) -> some ChartContent {
        if isFlat(bands) {
            ForEach(bands, id: \.self) { band in
                LineMark(
                    x: .value("Time", band.date),
                    y: .value("Forecast", display(band.low)),
                    series: .value("Forecast", Self.coneSeries)
                )
            }
            .interpolationMethod(.monotone)
            // Dashed, always. The measured trace is solid, so this is what stops
            // a forecast being read as readings that happened — worth more than
            // any amount of legibility, and not to be traded for it.
            .lineStyle(.init(lineWidth: lineWidth, dash: [3, 3]))
            .foregroundStyle(coneEdge(strong: true))
        } else {
            ForEach(bands, id: \.self) { band in
                AreaMark(
                    x: .value("Time", band.date),
                    yStart: .value("Forecast low", display(band.low)),
                    yEnd: .value("Forecast high", display(band.high)),
                    series: .value("Forecast", Self.coneSeries)
                )
            }
            // Monotone for the same reason as the readings' line: an
            // overshooting spline would draw a dip the model never predicted.
            .interpolationMethod(.monotone)
            .foregroundStyle(coneFill(strong: false))

            // Drawn over the fill so a narrow envelope still has something to
            // see. Each edge is its own series or Charts joins them into one
            // line that runs out along the top and back along the bottom.
            ForEach(bands, id: \.self) { band in
                LineMark(
                    x: .value("Time", band.date),
                    y: .value("Forecast high", display(band.high)),
                    series: .value("Forecast", Self.coneSeries - 1)
                )
            }
            .interpolationMethod(.monotone)
            .lineStyle(.init(lineWidth: lineWidth, dash: [3, 3]))
            .foregroundStyle(coneEdge(strong: false))

            ForEach(bands, id: \.self) { band in
                LineMark(
                    x: .value("Time", band.date),
                    y: .value("Forecast low", display(band.low)),
                    series: .value("Forecast", Self.coneSeries - 2)
                )
            }
            .interpolationMethod(.monotone)
            .lineStyle(.init(lineWidth: lineWidth, dash: [3, 3]))
            .foregroundStyle(coneEdge(strong: false))
        }
    }

    /// What the forecast is worth saying to a reader who cannot see it. The end
    /// of the envelope is given as the range it is, never as one number.
    private func forecastLabel(_ bands: [GlucosePredictionBand]) -> String {
        guard let last = bands.last else { return "" }
        let minutes = Int(last.date.timeIntervalSince(now) / 60)
        let low = spoken(last.low)
        let high = spoken(last.high)
        let range = isFlat(bands) ? low : "\(low) to \(high)"
        return "Forecast, not a reading. In \(minutes) minutes, \(range) \(unit.displayName)."
    }

    private func spoken(_ mgdl: Double) -> String {
        let value = display(mgdl)
        switch unit {
        case .mgdl: return String(format: "%.0f", value)
        case .mmol: return String(format: "%.1f", value)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            chart(height: proxy.size.height)
        }
    }

    private func chart(height: CGFloat) -> some View {
        let visible = points
        // Marks are drawn from `drawn` and the scale from `visible`: the extra
        // reading exists to be clipped, not to be measured.
        let drawn = drawnPoints
        let t = thresholds

        let forecast = bands

        let start = now.addingTimeInterval(-window - edgeSlack)
        let lastReading = visible.last?.date ?? now

        // Room for the horizon rather than for what is left of the cone. A
        // forecast is anchored to the cycle it came from, so its far end stands
        // still while the entries walk the now line toward it, and ending the
        // scale there took the span in a little further every entry. The width
        // does not change, so the same history came out wider each time: the
        // chart breathed instead of scrolling. Measuring the far edge from the
        // render's own moment fixes the span, so the readings only translate and
        // the cone recedes into the room held for it, which is its age drawn to
        // scale. The room goes with the cone: none is held where no forecast is
        // drawn, so a horizon picked against a loop that publishes none costs
        // nothing, and a spent cone leaves the chart shaped as it was without one.
        let end: Date
        if let tail = forecast.last?.date {
            // A cone ends in its own taper and clipping a taper costs nothing, so
            // the trailing slack is still spent only on a measured mark: a reading
            // stamped past the held room, which is a clock running ahead. `tail`
            // is here for the same reason, since a forecast anchored a little
            // ahead of us reaches past that room too.
            end = max(
                now.addingTimeInterval(effectiveForecast),
                tail,
                lastReading.addingTimeInterval(edgeSlack)
            )
        } else {
            end = max(now, lastReading).addingTimeInterval(edgeSlack)
        }

        // The forecast is allowed to open the scale. A predicted low clipped out
        // of view is the one failure worth avoiding here, and history flattening
        // under a dramatic forecast is honest about what is on screen.
        let content = domainMgdl(
            for: visible.map(\.value) + forecast.flatMap { [$0.low, $0.high] },
            thresholds: t
        )
        let domain = plotted(content, height: height)

        return Chart {
            // Beneath everything measured: the forecast never covers a reading
            // or a threshold line.
            if !forecast.isEmpty {
                coneMarks(forecast)
            }

            // Where measurement stops. With a forecast that is the seam the eye
            // would otherwise read as one continuous trace; without one it is
            // the near edge of the empty stretch the window opens as it walks
            // forward, which is the reading's age drawn to scale.
            //
            // Solid, and the only solid rule on the chart: the grid lines and
            // both thresholds are dashed, and a dashed divider at this weight
            // was not tellable from a grid line.
            if !visible.isEmpty || !forecast.isEmpty {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(nowRuleStyle)
                    .lineStyle(.init(lineWidth: 1.2))
            }

            // Under the rule marks: they are what the fill is measured against,
            // so they have to stay readable over it.
            if style == .area {
                areaMarks(drawn, thresholds: t)
            }

            RuleMark(y: .value("High", display(t.high)))
                .foregroundStyle(Color(.systemOrange).opacity(isFullColor ? 0.7 : 0.4))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            RuleMark(y: .value("Low", display(t.low)))
                .foregroundStyle(Color(.systemRed).opacity(isFullColor ? 0.7 : 0.4))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            if style.drawsLine {
                ForEach(Array(runs(drawn, thresholds: t).enumerated()), id: \.offset) { index, run in
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
                        .foregroundStyle(color(forBand: runBand(run, thresholds: t)).opacity(isFullColor ? 1 : 0.55))
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
        .accessibilityLabel(forecast.isEmpty ? "" : forecastLabel(forecast))
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
        duration: .standard,
        now: now
    )
    .frame(height: 103)
}
