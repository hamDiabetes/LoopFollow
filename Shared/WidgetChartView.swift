// LoopFollow
// WidgetChartView.swift

import Charts
import SwiftUI
import WidgetKit

/// Where the insulin ribbon sits relative to the glucose line.
enum InsulinRibbonPlacement {
    /// Below, running as deep as the insulin takes it. What ships.
    case belowUnclipped

    /// Below, but never into the band under the low line.
    ///
    /// **Overruled, and kept so the choice stays visible.** The argument was
    /// that the band under the low line is already spoken for — a fill down
    /// there means the reading was low, and a dose is not a reading — so the
    /// ribbon stopped at the low line and took an edge instead. Justin looked at
    /// it and said the ribbon should be able to go into the low space: what he
    /// wants to see during a low is how much insulin was still working, and
    /// clipping hid exactly that, at exactly the moment it mattered most.
    ///
    /// So the competing-colour problem is real and is not the one to solve by
    /// removing the information.
    case belowClipped

    /// Above, as the original sketch drew it on a fall.
    case above
}

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

    /// Insulin, carbs and rescue carbs, drawn as variable-width ribbons over the
    /// glucose line. Nil draws the chart exactly as it was before them.
    var ribbons: TreatmentRibbons?

    /// Which side of the glucose line the insulin ribbon takes.
    ///
    /// Below and unclipped, chosen by Justin from the drawing rather than from
    /// the argument. The third placement — above the trace, as the original
    /// sketch had it on a fall — is still unchosen, which is why the enum is
    /// still three cases rather than a Bool.
    var insulinPlacement: InsulinRibbonPlacement = .belowUnclipped
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

    /// What the loop is aiming at, as the steps it changed on. Nil where the
    /// producer does not send one — a profile aiming at a range rather than a
    /// number produces none, and so does a push from the app's own producer,
    /// which has no profile to read.
    var target: TargetSeries?

    /// The insulin ribbon's scale: units at full height, and how much of the
    /// plot full height is. Both are settings, read here so every surface picks
    /// up the same pair without each call site restating them.
    var insulinFullScaleUnits: Double = LAAppGroupSettings.insulinFullScaleUnits()
    var insulinHeightShare: Double = LAAppGroupSettings.insulinHeightShare()

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

    /// The trace's local slope where this reading sits, in points per point.
    ///
    /// A central difference where both neighbours are there, one-sided at the
    /// ends, and zero where the scale is unknown — a caller that cannot say how
    /// big the plot is gets the drawing it had before this existed.
    private func screenSlope(
        at index: Int,
        among visible: [GlucoseChartPoint],
        pointsPerValue: Double,
        pointsPerSecond: Double
    ) -> Double {
        guard pointsPerValue > 0, pointsPerSecond > 0, visible.count > 1 else { return 0 }
        let lower = max(0, index - 1)
        let upper = min(visible.count - 1, index + 1)
        guard lower != upper else { return 0 }
        let seconds = visible[upper].date.timeIntervalSince(visible[lower].date)
        guard seconds > 0, !Self.isGap(seconds) else { return 0 }
        let rise = (display(visible[upper].value) - display(visible[lower].value)) * pointsPerValue
        return rise / (seconds * pointsPerSecond)
    }

    /// One sample, as the span it describes: half a reading interval either
    /// side, clipped to the neighbours so it cannot reach into a moment the
    /// series says nothing about.
    ///
    /// Half, rather than up to the next reading, because a sample stands for the
    /// moment it was taken and the chart has no claim on the half of the gap
    /// that belongs to the reading after it.
    private static func widened(
        _ sample: RibbonSample,
        among visible: [GlucoseChartPoint],
        at index: Int
    ) -> [RibbonSample] {
        let before = index > 0 ? sample.date.timeIntervalSince(visible[index - 1].date) : standardReadingInterval
        let after = index < visible.count - 1 ? visible[index + 1].date.timeIntervalSince(sample.date) : standardReadingInterval
        let back = min(before, standardReadingInterval) / 2
        let forward = min(after, standardReadingInterval) / 2
        return [
            RibbonSample(date: sample.date.addingTimeInterval(-back), near: sample.near, far: sample.far),
            RibbonSample(date: sample.date.addingTimeInterval(forward), near: sample.near, far: sample.far),
        ]
    }

    /// What one reading stands for when nothing closer says otherwise.
    private static let standardReadingInterval: TimeInterval = 5 * 60

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

    /// The threshold a band's fill is measured against: the low line for
    /// everything at or above it, so the column under the trace is continuous
    /// and changes colour where the trace crosses. Below range the fill stands
    /// above the trace instead, where a reading near the floor of the chart
    /// still has room to be seen.
    ///
    /// A high excursion used to be anchored at the high line and left the
    /// in-range band hollow beneath it, which read as an excursion floating
    /// over a hole rather than as a column. It matters more now than it did:
    /// three ribbons and their hairlines sit over this fill, and a gap in it was
    /// one more horizontal edge among them.
    private func fillBaseline(thresholds t: (low: Double, high: Double)) -> Double {
        t.low
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
                    yStart: .value("Threshold", display(fillBaseline(thresholds: t))),
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

    // MARK: - Treatment ribbons

    /// Thickness, colour and side for the three treatment series.
    ///
    /// Widths are fractions of the plot height rather than point counts: the
    /// mockup's constants divided by the 338 point plot it was drawn against, so
    /// a ribbon claims the same share of a Live Activity as of a small widget.
    /// Internal rather than private so tests can measure what is drawn against
    /// the constants it is drawn from, rather than against a copy of them.
    enum Ribbon {
        static let opacity: Double = 0.65

        /// Share of the plot height per unit, for the producer that sends doses
        /// rather than insulin on board. Tuned against the mockup's plot and
        /// kept as it was, so that surface draws exactly what it drew before
        /// the insulin-on-board series existed.
        static let heightPerDose: Double = 0.20

        /// Share of the plot height per gram, for both carb series. Shared on
        /// purpose: the two are comparable by eye only if a gram is the same
        /// thickness in each.
        ///
        /// Rescue then multiplies it rather than replacing it, so the gram is
        /// still the same unit in both — see `rescueEmphasis`.
        static let heightPerGram: Double = 0.0024

        /// How much louder a rescue gram is drawn than a meal gram.
        ///
        /// The scale is kept shared and multiplied rather than replaced: a
        /// rescue gram is still measured in the same unit as a meal gram, and
        /// the emphasis is deliberate rather than two constants that happen to
        /// differ. A rescue entry is a smaller quantity doing a more urgent job
        /// — five or ten grams against a forty gram meal — and at true parity it
        /// is 2.3 points tall and disappears.
        static let rescueEmphasis: Double = 2.0

        /// No ribbon may claim more than this share of the plot, whatever the
        /// dose.
        static let maxHeightShare: Double = 0.25

        /// Clear space between the glucose line and the near edge of a ribbon,
        /// where the ribbon has any thickness at all.
        ///
        /// Without it a filled mass sharing an edge with the trace reads as part
        /// of it. Applied to every sample, though, it lifts the flat ends a run
        /// carries to taper with, so the shape converges to a line beside the
        /// trace instead of to the trace — a detached sliver that reads as the
        /// ribbon floating away from the line. The ends belong on the line and
        /// the body belongs off it: the ribbon then grows out of the trace,
        /// swells, and returns to it.
        static let gap: Double = 0.012

        /// The window a bolus is counted over, for deciding whether a reading
        /// covers it. The ribbon no longer totals doses — it draws insulin on
        /// board — but a dose with no reading anywhere near it still needs a
        /// marker, and this is the span that asks.
        static let insulinWindow: TimeInterval = 5 * 60

        static let insulin = Color(red: 0.184, green: 0.435, blue: 0.894)
        static let carbs = Color(red: 0.545, green: 0.361, blue: 0.965)
        static let rescue = Color(red: 0.651, green: 0.678, blue: 0.722)

        /// Rescue carbs on a tinted card. Gray is the one colour here with no hue
        /// to separate it from a saturated green or orange ground, so on those it
        /// is lightened towards white and drawn nearly opaque. At the shared
        /// opacity it was invisible on green.
        static let rescueOnTint = Color(red: 0.93, green: 0.94, blue: 0.96)
        static let rescueTintOpacity: Double = 0.92

        /// The edge stroke, as a share of the ribbon's own thickness.
        ///
        /// A fixed line is 6% of a 17 pt carb ribbon and 43% of a 2.3 pt rescue
        /// one, where it swallows the taper: a 6 g entry decays from 2.3 pt to
        /// nothing under a constant-width line, so the shape reads as a line
        /// that stops rather than a ribbon that fades. Proportional at the top
        /// end, floored at the bottom — a stroke that scales to nothing loses
        /// the edge that stops a ribbon reading as a threshold band, which is
        /// why it is drawn at all.
        static let strokeShareOfThickness: Double = 0.06
        static let strokeWidthRange: ClosedRange<Double> = 0.5 ... 1

        /// The hairline that says the chart knows this series' value here, even
        /// where that value is zero. Thinner than any ribbon edge, because it is
        /// a statement about knowledge rather than about magnitude.
        static let baselineWidth: Double = 0.5

        /// How far inside the plot a marker for an undrawable treatment sits.
        /// Far enough from the edge to be a mark rather than a clipped one.
        static let markerInset: Double = 0.06

        /// Small: worth saying the treatment happened, not worth as much of the
        /// eye as one the chart could place.
        static let markerSize: Double = 14
    }

    /// One plotted ribbon: a filled shape between the glucose line and an offset
    /// from it, with the offset carrying the magnitude.
    ///
    /// One per stretch where the series has any thickness, rather than one per
    /// series: a ribbon of zero width still draws its edge, which would be a
    /// line the length of the chart in a colour that means a treatment.
    struct RibbonShape: Identifiable {
        let id: String

        /// Which series this came from, since the opacity depends on it and the
        /// id no longer says.
        let kind: String
        let color: Color
        let samples: [RibbonSample]
    }

    struct RibbonSample: Hashable {
        let date: Date
        let near: Double
        let far: Double
    }

    /// One treatment the chart could not give a ribbon, drawn at its own time.
    ///
    /// A ribbon rides the glucose curve, so a treatment given while the sensor
    /// was out has nothing to ride and renders as nothing at all. A marker
    /// stands in — the one from the original sketch, for the one case that needs
    /// it. A degraded state, not a second design.
    private struct RibbonMarker: Identifiable {
        let id: String
        let date: Date
        let color: Color
        let kind: String

        /// Same side the series' ribbon would have taken, so a marker means the
        /// same direction the ribbon does.
        let above: Bool
    }

    /// Builds the shapes, in display units.
    ///
    /// `far` is offset from the glucose value by the magnitude, on the side that
    /// carries the direction: carbs above the line because they raise glucose,
    /// insulin below because it lowers it. Sampled at the readings rather than on
    /// a grid of its own, so a ribbon follows the curve exactly and inherits the
    /// same gaps.
    /// Internal so a test can ask the view what it draws. Every test of ribbon
    /// geometry that recomputed this formula in its own body agreed with a view
    /// that had stopped doing the same multiplication.
    func ribbonShapes(
        _ visible: [GlucoseChartPoint],
        span: Double,
        pointsPerValue: Double = 0,
        pointsPerSecond: Double = 0
    ) -> (shapes: [RibbonShape], baselines: [RibbonShape]) {
        guard let ribbons, !ribbons.isEmpty, span > 0, !visible.isEmpty else { return ([], []) }

        var baselines: [RibbonShape] = []

        // Where the readings break, the ribbons break with them. A ribbon may
        // not assert a continuity the glucose series denies: its near boundary
        // is the trace itself, so a shape drawn across a dropout reinstates, in
        // another colour, the curve the line above refuses to draw.
        let gapAfter = visible.indices.map { index -> Bool in
            guard index < visible.count - 1 else { return false }
            return Self.isGap(visible[index + 1].date.timeIntervalSince(visible[index].date))
        }

        // A nil magnitude is not a thin ribbon, it is no answer: the series says
        // nothing about that moment. Those samples are held out of every shape,
        // so a stretch with no data is a gap in the ribbon the way a sensor
        // dropout is a gap in the line.
        //
        // **A hairline belongs to a state series and not to an event series,
        // and that is the whole rule.** Carbs on board is a state the loop
        // reports every cycle, so a mark over a zero stretch says something
        // real — it was watching, and there was nothing on board — and without
        // it zero and unknown are the same pixels. Rescue is an event series:
        // its absence is the ordinary reading of the chart, not a claim anybody
        // needs marked, because nobody assumes a rescue carb they cannot see.
        // Justin settled it by removing rescue's rather than conditioning it.
        //
        // Insulin sits on both sides of that line and switches with the
        // producer: a state series on the `.onBoard` path, an event series on
        // `.doses`, which is exactly what `insulinKnows` below reads.
        //
        // Rescue's hairline was also drawn at the same offset as the carb one
        // and painted second, so wherever rescue had stated coverage — which on
        // the widget is always — the carb hairline was covered. Deleting it is
        // what makes the mark the carb series needs actually visible.
        let statedCoverage = ribbons.coveredFrom != nil

        func shapes(
            _ kind: String,
            _ color: Color,
            above: Bool,
            floor: Double? = nil,
            knows: ((Date) -> Bool)? = nil,
            baseline: Bool = true,
            _ magnitude: (Date) -> Double?
        ) -> [RibbonShape] {
            var samples: [RibbonSample?] = []
            var baselineSamples: [RibbonSample?] = []
            var carries: [Bool] = []
            for (index, point) in visible.enumerated() {
                guard covers(point.date), let value = magnitude(point.date) else {
                    samples.append(nil)
                    baselineSamples.append(nil)
                    carries.append(false)
                    continue
                }
                let share = min(value, Ribbon.maxHeightShare)
                let line = display(point.value)
                let (near, far) = RibbonGeometry.edges(
                    line: line,
                    share: share,
                    span: span,
                    above: above,
                    gap: Ribbon.gap,
                    floor: floor,
                    screenSlope: screenSlope(at: index, among: visible, pointsPerValue: pointsPerValue, pointsPerSecond: pointsPerSecond)
                )
                let baselineNear = RibbonGeometry.baselineEdge(
                    line: line,
                    span: span,
                    above: above,
                    gap: Ribbon.gap
                )
                baselineSamples.append(RibbonSample(date: point.date, near: baselineNear, far: baselineNear))
                samples.append(RibbonSample(date: point.date, near: near, far: far))
                carries.append(share > 0)
            }

            // Every stretch the series has a value for, zero included, drawn as
            // a hairline along the near edge. See `RibbonBaseline`.
            let known = visible.indices.map { index in
                knows.map { $0(visible[index].date) } ?? (samples[index] != nil)
            }
            baselines += baseline ? RibbonBaseline.runs(known: known, gapAfter: gapAfter)
                .map { range in
                    RibbonShape(
                        id: "\(kind)-base-\(range.lowerBound)",
                        kind: kind,
                        color: color,
                        samples: baselineSamples[range].compactMap { $0 }
                    )
                } : []

            // Each run of thickness, with the flat sample either side of it kept
            // so the shape tapers into the line rather than starting at a wall.
            //
            // Only where that neighbour is an answer and no gap intervenes. A
            // taper into an unknown would draw the series returning to zero at a
            // moment nobody reported one, and a taper across a dropout would
            // cross it; the run stops square in both cases and what is missing
            // stays visibly missing.
            var runs: [RibbonShape] = []
            var start: Int?
            for index in carries.indices {
                if carries[index], start == nil { start = index }
                guard let first = start else { continue }
                let ends = index == carries.count - 1 || !carries[index + 1] || gapAfter[index]
                guard ends else { continue }
                let lower = first > 0 && samples[first - 1] != nil && !gapAfter[first - 1] ? first - 1 : first
                let upper = index < samples.count - 1 && samples[index + 1] != nil && !gapAfter[index] ? index + 1 : index
                let drawn = samples[lower ... upper].compactMap { $0 }
                runs.append(RibbonShape(
                    id: "\(kind)-\(runs.count)",
                    kind: kind,
                    color: color,
                    // A run of one is given the extent it stands for rather than
                    // drawn as an instant. An area is a shape between two
                    // points, so one point draws nothing at all — which is how a
                    // series that answers for a reading can still be invisible,
                    // and it is the second half of the lone-sample defect: the
                    // grid fix made the chart know, and this is what makes it
                    // draw. Interval, the same answer this question has had
                    // everywhere else it has come up.
                    samples: drawn.count == 1 ? Self.widened(drawn[0], among: visible, at: first) : drawn
                ))
                start = nil
            }
            return runs
        }

        // Insulin is a state series when the loop's own figure is there and an
        // event series when it is not, so what it knows depends on which.
        let insulinKnows: ((Date) -> Bool)? = InsulinRibbonSource.choose(insulinOnBoard: ribbons.insulinOnBoard) == .doses
            ? { statedCoverage && covers($0) }
            : nil

        let drawn = shapes("insulin", Ribbon.insulin, above: insulinAbove, floor: insulinFloor, knows: insulinKnows) { date in
            // Insulin on board rather than doses in a window: a standing
            // quantity, the way the carb ribbon already is. Full height is the
            // units somebody set, so what a thickness means does not move
            // through the day.
            //
            // A producer that sends no such series gets the older ribbon
            // instead. Which one is `InsulinRibbonSource`'s to say, on nil
            // against empty.
            switch InsulinRibbonSource.choose(insulinOnBoard: ribbons.insulinOnBoard) {
            case .onBoard:
                return RibbonSampler.insulinOnBoard(ribbons.insulinOnBoard, at: date, observed: ribbons.insulinObserved)
                    .value
                    .map { InsulinOnBoard.share(of: $0, fullScaleUnits: insulinFullScaleUnits) * insulinHeightShare }
            case .doses:
                return RibbonSampler.insulin(ribbons.insulin, at: date, window: Ribbon.insulinWindow)
                    .map { $0 * Ribbon.heightPerDose }
            }
        } + shapes("carbs", Ribbon.carbs, above: true) { date in
            RibbonSampler.carbsOnBoard(ribbons.carbsOnBoard, at: date, observed: ribbons.carbsObserved).value.map { $0 * Ribbon.heightPerGram }
        } + shapes("rescue", rescueColor, above: true, knows: { statedCoverage && covers($0) }, baseline: false) { date in
            RibbonSampler.rescue(ribbons.rescue, at: date, rate: ribbons.carbsPerHour)
                .map { $0 * Ribbon.heightPerGram * Ribbon.rescueEmphasis }
        }
        return (drawn, baselines)
    }

    private var insulinAbove: Bool { insulinPlacement.isAbove }

    private var insulinFloor: Double? { insulinPlacement.floor(low: display(thresholds.low)) }

    private var rescueColor: Color {
        onTintedBackground ? Ribbon.rescueOnTint : Ribbon.rescue
    }

    /// Whether the ribbons claim to describe this moment at all.
    ///
    /// A Live Activity push says how far back its treatments reach, because the
    /// relay trims that history first when a payload will not fit. Outside it
    /// there is nothing to draw and, more to the point, nothing to conclude.
    private func covers(_ date: Date) -> Bool {
        guard let from = ribbons?.coveredFrom else { return true }
        return date >= from
    }

    /// The treatments that fall where no ribbon can be drawn.
    ///
    /// `RibbonOrphans` decides which, asking the samplers that draw the series.
    /// All this adds is the coverage filter, the colour and the side.
    private func ribbonMarkers(_ visible: [GlucoseChartPoint]) -> [RibbonMarker] {
        guard let ribbons else { return [] }

        let readings = visible.map(\.date)
        let insulin = RibbonOrphans.insulin(
            ribbons.insulin?.filter { covers($0.date) },
            readings: readings,
            window: Ribbon.insulinWindow
        )
        let rescue = RibbonOrphans.rescue(
            ribbons.rescue?.filter { covers($0.date) },
            readings: readings,
            rate: ribbons.carbsPerHour
        )

        // Treatments only. A carbs-on-board sample is an observation rather
        // than an event, so a gap in it is a gap and not a treatment the chart
        // could not place — see `RibbonOrphans`.
        return insulin.map { RibbonMarker(id: "insulin-\($0.timeIntervalSince1970)", date: $0, color: Ribbon.insulin, kind: "insulin", above: insulinAbove) }
            + rescue.map { RibbonMarker(id: "rescue-\($0.timeIntervalSince1970)", date: $0, color: rescueColor, kind: "rescue", above: true) }
    }

    private func opacity(for kind: String) -> Double {
        guard onTintedBackground else { return Ribbon.opacity }
        return kind == "rescue" ? Ribbon.rescueTintOpacity : min(1, Ribbon.opacity * 1.3)
    }

    /// The stroke for one shape, from how thick it actually draws.
    ///
    /// Thickness in points is the shape's share of the domain times the plot's
    /// height: the reserves widen the domain rather than shrinking the canvas,
    /// so nothing else comes into it.
    private func strokeWidth(for ribbon: RibbonShape, span: Double, height: CGFloat) -> Double {
        guard span > 0, height > 0 else { return Ribbon.strokeWidthRange.upperBound }
        let thickest = ribbon.samples.map { abs($0.far - $0.near) }.max() ?? 0
        let points = thickest / span * Double(height)
        return min(
            Ribbon.strokeWidthRange.upperBound,
            max(Ribbon.strokeWidthRange.lowerBound, points * Ribbon.strokeShareOfThickness)
        )
    }

    private func ribbonMarks(_ shapes: [RibbonShape], span: Double, height: CGFloat) -> some ChartContent {
        ForEach(shapes) { ribbon in
            ForEach(ribbon.samples, id: \.self) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    yStart: .value("Glucose", sample.near),
                    yEnd: .value("Treatment", sample.far),
                    series: .value("Ribbon", ribbon.id)
                )
            }
            .interpolationMethod(.monotone)
            // The tinted Live Activity ground sits much closer to these colours
            // than the widget's neutral panel does, so the gray in particular
            // needs more weight there to stay a ribbon rather than a smudge.
            .foregroundStyle(ribbon.color.opacity(opacity(for: ribbon.kind)))

            // An edge along the outer boundary. Without it a ribbon fades into
            // the band fills this chart already draws under the trace, and a
            // soft-edged mass below a falling line reads as a threshold region
            // rather than as a dose.
            ForEach(ribbon.samples, id: \.self) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Treatment", sample.far),
                    series: .value("Ribbon edge", ribbon.id)
                )
            }
            .interpolationMethod(.monotone)
            .lineStyle(.init(lineWidth: strokeWidth(for: ribbon, span: span, height: height), lineCap: .round, lineJoin: .round))
            .foregroundStyle(ribbon.color.opacity(min(1, opacity(for: ribbon.kind) + 0.3)))
        }
    }

    /// The hairlines, drawn along each series' near edge wherever it has a value
    /// — including zero, which is the whole point of them.
    private func baselineMarks(_ baselines: [RibbonShape]) -> some ChartContent {
        ForEach(baselines) { baseline in
            ForEach(baseline.samples, id: \.self) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Known", sample.near),
                    series: .value("Baseline", baseline.id)
                )
            }
            .interpolationMethod(.monotone)
            .lineStyle(.init(lineWidth: Ribbon.baselineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(baseline.color.opacity(baselineOpacity))
        }
    }

    /// The target the loop is aiming at, drawn as the step function it is.
    ///
    /// Dashed, and green, which Justin chose knowing the risk: green is this
    /// chart's word for in range, and it is also the Live Activity's own ground
    /// on a good day. The colour holds and the rendering adapts — the same
    /// answer `Ribbon.rescueOnTint` reached when gray disappeared on green.
    ///
    /// Drawn as a line through the plotted moments rather than as a rule, since
    /// a target that changes is a step and a rule is one height for the whole
    /// chart.
    private func targetMarks(_ visible: [GlucoseChartPoint]) -> some ChartContent {
        let stated: [(date: Date, mgdl: Double)] = (target?.isEmpty == false ? visible : [])
            .compactMap { point in
                target?.target(at: point.date).map { (point.date, $0) }
            }

        return ForEach(stated, id: \.date) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Target", display(point.mgdl)),
                series: .value("Target", "target")
            )
        }
        .interpolationMethod(.stepEnd)
        .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
        .foregroundStyle(targetColor)
    }

    /// Green on the widget's neutral panel; a lighter green, drawn harder, on a
    /// tinted card. Measured on all three tints: the plain systemGreen is
    /// invisible on the in-range ground, which is the one it matters on.
    private var targetColor: Color {
        onTintedBackground
            ? Color(red: 0.82, green: 1.0, blue: 0.85).opacity(0.95)
            : Color(.systemGreen).opacity(0.85)
    }

    /// The hairline is the thinnest mark on the chart, so it is drawn harder on
    /// a saturated Live Activity ground than on the widget's neutral panel.
    private var baselineOpacity: Double {
        onTintedBackground ? 0.95 : 0.75
    }

    /// Held against the edge of the plot rather than placed at a height. A
    /// marker in the middle of an empty stretch would be read as a reading; one
    /// sitting on the boundary is plainly an annotation, and it keeps the side
    /// that says which way the treatment pushes glucose.
    private func markerMarks(_ visible: [GlucoseChartPoint], domain: ClosedRange<Double>) -> some ChartContent {
        let span = domain.upperBound - domain.lowerBound
        let top = domain.upperBound - span * Ribbon.markerInset
        let bottom = domain.lowerBound + span * Ribbon.markerInset

        return ForEach(ribbonMarkers(visible)) { marker in
            PointMark(
                x: .value("Time", marker.date),
                y: .value("Treatment", marker.above ? top : bottom)
            )
            .symbolSize(Ribbon.markerSize)
            .foregroundStyle(marker.color.opacity(min(1, opacity(for: marker.kind) + 0.3)))
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
            chart(height: proxy.size.height, width: proxy.size.width)
        }
    }

    private func chart(height: CGFloat, width: CGFloat) -> some View {
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
        // Built once: the baselines and the ribbons come out of the same pass.
        let ribbonSpan = display(domain.upperBound) - display(domain.lowerBound)
        // Points per glucose unit and per second, so the ribbons can be widened
        // where the trace is steep: the offset is vertical and what is read is
        // the width across the band.
        let built = ribbonShapes(
            drawn,
            span: ribbonSpan,
            pointsPerValue: ribbonSpan > 0 ? Double(height) / ribbonSpan : 0,
            pointsPerSecond: Double(width) / max(end.timeIntervalSince(start), 1)
        )

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

            targetMarks(drawn)

            RuleMark(y: .value("Low", display(t.low)))
                .foregroundStyle(Color(.systemRed).opacity(isFullColor ? 0.7 : 0.4))
                .lineStyle(.init(lineWidth: 1, dash: [4, 4]))

            // Under the glucose line, and held off it by `Ribbon.gap`.
            //
            // Drawn over the line these read as part of the trace rather than
            // as something measured against it, and at three series deep the
            // line stops being findable at all. The reading is the thing a
            // caregiver came for; the ribbons are context for it.
            baselineMarks(built.baselines)
            ribbonMarks(built.shapes, span: ribbonSpan, height: height)

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

            markerMarks(drawn, domain: display(domain.lowerBound) ... display(domain.upperBound))
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
