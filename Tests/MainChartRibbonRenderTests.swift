// LoopFollow
// MainChartRibbonRenderTests.swift

import Foundation
import SwiftUI
@testable import LoopFollow
import Testing

/// What the in-app chart does differently from the widget.
///
/// The ribbons themselves come from `WidgetChartView.ribbonShapes` and the
/// geometry from `RibbonGeometry`, both covered already and neither re-checked
/// here. What is left is the scale this chart resolves those shares against, the
/// stroke it measures off them, and the target line it builds from the steps —
/// which is the whole of what had no test before.
struct MainChartRibbonRenderTests {
    let anchor = Date(timeIntervalSince1970: 1_757_000_000)

    /// Flat readings, so the shear compensation is exactly one and a thickness
    /// is the share and nothing else.
    private func readings(_ count: Int) -> [GlucoseChartPoint] {
        (0 ..< count).map {
            GlucoseChartPoint(value: 140, date: anchor.addingTimeInterval(37 + Double($0) * 300))
        }
    }

    /// One unit a minute before each reading, on the dose path: nil insulin on
    /// board is what chooses it.
    private func doses(_ points: [GlucoseChartPoint]) -> TreatmentRibbons {
        TreatmentRibbons(
            insulin: points.map { TreatmentEvent(date: $0.date.addingTimeInterval(-60), amount: 1) },
            carbsOnBoard: [],
            rescue: []
        )
    }

    /// The thickest insulin sample, in points.
    private func insulinPoints(_ points: [GlucoseChartPoint], pointsPerValue: Double) -> Double? {
        let built = MainChartRibbons.shapes(
            doses(points),
            readings: points,
            now: points.last?.date ?? anchor,
            pointsPerValue: pointsPerValue,
            pointsPerSecond: 0.02
        )
        let thickest = built.shapes
            .filter { $0.kind == "insulin" }
            .flatMap(\.samples)
            .map { abs($0.near - $0.far) }
            .max()
        return thickest.map { $0 * pointsPerValue }
    }

    /// A dose is the same thickness on screen whatever the y domain is doing.
    ///
    /// This chart's domain is `0 ... maxBG` and `maxBG` moves with the data, so
    /// a share resolved against it draws a dose at one thickness tonight and
    /// another tomorrow. Drop the division in `span` and the two measurements
    /// here come out a factor apart.
    @Test func aDoseIsTheSameThicknessWhateverTheDomain() throws {
        let points = readings(6)
        // A 280 pt plot over a 250 mg/dL domain, and over a 400 mg/dL one.
        let tight = try #require(insulinPoints(points, pointsPerValue: 280.0 / 250))
        let wide = try #require(insulinPoints(points, pointsPerValue: 280.0 / 400))

        #expect(abs(tight - wide) < 0.01)
        // One unit at 0.20 of full scale, over the 338 pt the shares are quoted
        // against.
        #expect(abs(tight - 0.20 * MainChartRibbons.fullScalePoints) < 0.5)
    }

    private func shape(thicknessMgdl: Double) -> WidgetChartView.RibbonShape {
        WidgetChartView.RibbonShape(
            id: "insulin-0",
            kind: "insulin",
            color: .blue,
            samples: [
                WidgetChartView.RibbonSample(date: anchor, near: 140, far: 140 - thicknessMgdl),
                WidgetChartView.RibbonSample(date: anchor.addingTimeInterval(300), near: 140, far: 140),
            ]
        )
    }

    /// The stroke is measured off the drawn thickness, and it is floored so a
    /// ribbon that tapers to nothing keeps the edge that stops it reading as a
    /// threshold band.
    @Test func theStrokeFollowsTheThicknessBetweenItsBounds() {
        let range = WidgetChartView.Ribbon.strokeWidthRange
        let perValue = 280.0 / 250

        // 10 mg/dL is 11.2 pt, and 6% of that is inside the range.
        let middle = MainChartRibbons.strokeWidth(for: shape(thicknessMgdl: 10), pointsPerValue: perValue)
        #expect(abs(middle - 11.2 * WidgetChartView.Ribbon.strokeShareOfThickness) < 0.01)

        #expect(MainChartRibbons.strokeWidth(for: shape(thicknessMgdl: 0.2), pointsPerValue: perValue) == range.lowerBound)
        #expect(MainChartRibbons.strokeWidth(for: shape(thicknessMgdl: 200), pointsPerValue: perValue) == range.upperBound)
    }

    /// The same shape on a taller plot draws a heavier edge, which is what
    /// measuring in points rather than in mg/dL means.
    @Test func theStrokeIsMeasuredInPoints() {
        let thin = MainChartRibbons.strokeWidth(for: shape(thicknessMgdl: 8), pointsPerValue: 0.4)
        let thick = MainChartRibbons.strokeWidth(for: shape(thicknessMgdl: 8), pointsPerValue: 1.6)
        #expect(thick > thin)
    }

    private func target(_ offsets: [(TimeInterval, Double)]) -> TargetSeries {
        TargetSeries(steps: offsets.map { TargetSeries.Step(date: anchor.addingTimeInterval($0.0), mgdl: $0.1) })
    }

    /// The line spans the window rather than starting at the first change inside
    /// it: a window opening mid-segment still has a target in force.
    @Test func theTargetSpansTheWindow() throws {
        let series = target([(0, 100), (3600, 110), (7200, 120), (86400, 130)])
        let steps = MainChartRibbons.targetSteps(
            series,
            from: anchor.addingTimeInterval(1800),
            to: anchor.addingTimeInterval(5400)
        )

        #expect(steps.count == 3)
        #expect(steps.first?.date == anchor.addingTimeInterval(1800))
        // In force at the opening, which is the 3600 step's predecessor.
        #expect(steps.first?.mgdl == 100)
        #expect(steps[1].mgdl == 110)
        // Held to the window's end rather than stopping at the last change.
        #expect(steps.last?.date == anchor.addingTimeInterval(5400))
        #expect(steps.last?.mgdl == 110)
    }

    /// Nothing is drawn before the series begins. A target published this
    /// morning says nothing about last night, and the chart pans back into it.
    @Test func noTargetIsDrawnBeforeTheSeriesBegins() {
        let series = target([(3600, 110)])
        let steps = MainChartRibbons.targetSteps(
            series,
            from: anchor.addingTimeInterval(-3600),
            to: anchor
        )
        #expect(steps.isEmpty)
    }

    /// A step exactly at the window's opening is the opening value, not a second
    /// step on top of it.
    @Test func aStepOnTheWindowsEdgeIsNotDrawnTwice() {
        let steps = MainChartRibbons.targetSteps(
            target([(0, 100)]),
            from: anchor,
            to: anchor.addingTimeInterval(3600)
        )
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.mgdl == 100 })
    }
}
