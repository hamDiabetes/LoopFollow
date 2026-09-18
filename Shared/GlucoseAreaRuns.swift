// LoopFollow
// GlucoseAreaRuns.swift

import Foundation

/// Splitting a glucose trace into the coloured stretches an area fill is drawn
/// from.
///
/// Moved out of `WidgetChartView` whole rather than reimplemented, because the
/// main chart now draws the same fill and two copies of this would drift. The
/// rules it encodes were each arrived at from something that looked wrong on a
/// screen, and none of them survive being derived a second time from scratch:
/// runs meet on the threshold crossing rather than on the first reading past
/// it, a run takes its colour from the reading furthest inside it, and a sensor
/// dropout separates runs so no fill is drawn across it.
///
/// Pure, and every input is passed in. Nothing here knows what a widget is,
/// which is what lets the app's chart ask the same question.
enum GlucoseAreaRuns {
    /// Longer than this between two readings and the trace is cut rather than
    /// carried across: a curve drawn through a sensor dropout is history that
    /// never happened. Three missed readings at the usual five minute cadence.
    static let maxGap: TimeInterval = 20 * 60

    static func isGap(_ interval: TimeInterval) -> Bool {
        interval >= maxGap
    }

    /// Which side of the range a reading falls on: below, in, or above.
    static func band(_ mgdl: Double, thresholds t: (low: Double, high: Double)) -> Int {
        if mgdl < t.low { return -1 } else if mgdl > t.high { return 1 } else { return 0 }
    }

    /// Splits the readings into stretches that can each be drawn as one line: a
    /// new run starts wherever the colour changes or the sensor stopped
    /// reporting. Runs that meet in time repeat the joining reading, so a change
    /// of colour leaves no hole in the trace, while a gap does.
    static func runs(
        _ visible: [GlucoseChartPoint],
        thresholds t: (low: Double, high: Double),
        isGap: (TimeInterval) -> Bool
    ) -> [[GlucoseChartPoint]] {
        var result: [[GlucoseChartPoint]] = []
        var current: [GlucoseChartPoint] = []

        for point in visible {
            guard let previous = current.last else {
                current = [point]
                continue
            }
            if isGap(point.date.timeIntervalSince(previous.date)) {
                result.append(current)
                current = [point]
            } else if band(previous.value, thresholds: t) != band(point.value, thresholds: t) {
                // Both runs meet on the threshold itself rather than on the
                // first reading past it. Sharing the reading let a run keep its
                // colour a whole segment into the next band, so a trace on its
                // way up stayed green until it was already high — which reads
                // as in range for five minutes it was not.
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
    /// Runs begin and end on the threshold crossings, and a crossing sits
    /// exactly on a threshold — which `band` reads as in range, whichever side
    /// the run is actually on. Measuring from the extreme picks a real reading
    /// whenever the run has one, so a two-reading excursion is still coloured by
    /// the excursion rather than by the line it crossed to get there.
    static func runBand(_ run: [GlucoseChartPoint], thresholds t: (low: Double, high: Double)) -> Int {
        let distance = { (p: GlucoseChartPoint) in min(abs(p.value - t.low), abs(p.value - t.high)) }
        let anchor = run.max { distance($0) < distance($1) } ?? run[0]
        return band(anchor.value, thresholds: t)
    }

    /// Where the trace passes a threshold between two readings that sit in
    /// different bands, by linear interpolation. Anchoring both fills there
    /// keeps one band's colour out of the next one's segment.
    static func crossing(
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

    /// The threshold a band's fill is measured against: the low line for
    /// everything at or above it, so the column under the trace is continuous
    /// and changes colour where the trace crosses. Below range the fill stands
    /// above the trace instead, where a reading near the floor of the chart
    /// still has room to be seen.
    static func fillBaseline(thresholds t: (low: Double, high: Double)) -> Double {
        t.low
    }

    /// The line style's runs, with the reading two of them share replaced by
    /// the point where the trace crosses between their bands. Both fills then
    /// meet on the rule mark, instead of one band's colour reaching a segment
    /// into the next. Runs the gap rule separated stay apart, so no fill is
    /// drawn across a sensor dropout.
    static func areaRuns(
        _ visible: [GlucoseChartPoint],
        thresholds t: (low: Double, high: Double),
        isGap: (TimeInterval) -> Bool
    ) -> [(band: Int, points: [GlucoseChartPoint])] {
        var result: [(band: Int, points: [GlucoseChartPoint])] = []
        var pending: GlucoseChartPoint?

        for run in runs(visible, thresholds: t, isGap: isGap) {
            guard !run.isEmpty else { continue }
            // Not the first reading: runs begin on a threshold crossing, and a
            // value sitting exactly on a threshold reads as in range whichever
            // side the run is really on.
            let runsBand = runBand(run, thresholds: t)

            var points = run
            if let joint = pending { points.insert(joint, at: 0) }
            pending = nil

            if points.count > 1, let tail = points.last, band(tail.value, thresholds: t) != runsBand {
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
            if deduped.count > 1 { result.append((runsBand, deduped)) }
        }
        return result
    }
}
