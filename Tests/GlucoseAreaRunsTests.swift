// LoopFollow
// GlucoseAreaRunsTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The rules that split a glucose trace into coloured stretches.
///
/// These were written when the logic moved out of `WidgetChartView` so the main
/// chart could draw the same fill. Nothing covered them before the move, which
/// means they are also what stands behind the claim that the move changed
/// nothing: each one states a behaviour the widget had, and the widget now
/// answers through this type.
struct GlucoseAreaRunsTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private let thresholds = (low: 70.0, high: 180.0)

    private func point(_ minutes: Double, _ value: Double) -> GlucoseChartPoint {
        GlucoseChartPoint(value: value, date: anchor.addingTimeInterval(minutes * 60))
    }

    private func runs(_ points: [GlucoseChartPoint]) -> [(band: Int, points: [GlucoseChartPoint])] {
        GlucoseAreaRuns.areaRuns(points, thresholds: thresholds, isGap: GlucoseAreaRuns.isGap)
    }

    @Test func aTraceInsideRangeIsOneRun() {
        let result = runs([point(0, 100), point(5, 110), point(10, 120)])

        #expect(result.count == 1)
        #expect(result[0].band == 0)
    }

    /// The colour has to change where the trace passes the line, not at the
    /// first reading beyond it — otherwise the chart reads as in range for the
    /// five minutes it was already high.
    @Test func runsMeetOnTheCrossingRatherThanOnTheFirstReadingPastIt() throws {
        let result = runs([point(0, 170), point(5, 190)])

        #expect(result.count == 2)
        let joint = try #require(result[0].points.last)
        #expect(joint.value == thresholds.high)
        #expect(joint.date > anchor && joint.date < anchor.addingTimeInterval(300))
        #expect(result[1].points.first == joint)
    }

    @Test func aRunIsColouredByItsExtremeNotByTheThresholdItCrossed() {
        let result = runs([point(0, 100), point(5, 260), point(10, 100)])

        #expect(result.map(\.band) == [0, 1, 0])
    }

    /// A curve drawn through a sensor dropout is history that never happened.
    @Test func aDropoutSeparatesRunsSoNoFillIsDrawnAcrossIt() {
        let result = runs([point(0, 100), point(5, 110), point(40, 115), point(45, 120)])

        #expect(result.count == 2)
        #expect(result[0].points.last?.date == anchor.addingTimeInterval(300))
        #expect(result[1].points.first?.date == anchor.addingTimeInterval(2400))
    }

    @Test func aGapShorterThanTheDropoutRuleDoesNotSplitTheTrace() {
        let result = runs([point(0, 100), point(15, 110)])

        #expect(result.count == 1)
    }

    @Test func aRunOfOneReadingIsNotDrawn() {
        #expect(runs([point(0, 100)]).isEmpty)
    }

    /// Below range the fill stands above the trace, so both directions are
    /// measured from the same line.
    @Test func theFillIsMeasuredFromTheLowThresholdInEveryBand() {
        #expect(GlucoseAreaRuns.fillBaseline(thresholds: thresholds) == thresholds.low)
    }

    @Test func aReadingOnAThresholdReadsAsInRange() {
        #expect(GlucoseAreaRuns.band(70, thresholds: thresholds) == 0)
        #expect(GlucoseAreaRuns.band(180, thresholds: thresholds) == 0)
        #expect(GlucoseAreaRuns.band(69.9, thresholds: thresholds) == -1)
        #expect(GlucoseAreaRuns.band(180.1, thresholds: thresholds) == 1)
    }

    /// A misordered threshold pair must not put the crossing outside the two
    /// readings it sits between.
    @Test func aCrossingStaysBetweenTheReadingsItWasDerivedFrom() {
        let from = point(0, 100)
        let to = point(5, 110)
        let crossing = GlucoseAreaRuns.crossing(from: from, to: to, thresholds: (low: 300, high: 400))

        #expect(crossing.date >= from.date)
        #expect(crossing.date <= to.date)
    }
}
