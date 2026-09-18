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
    }

    /// And that thickness is the one the widget draws for the same dose.
    ///
    /// **The reference plot is stated here rather than read from
    /// `fullScalePoints`.** That constant is the entire mechanism by which a
    /// dose is the same size on this chart as on the widget, it appears once in
    /// the tree, and a test that reads it agrees with whatever value it is
    /// given — the earlier version of this assertion multiplied by the constant
    /// it was checking and survived changing it.
    @Test func aDoseDrawsTheThicknessTheWidgetDrawsIt() throws {
        let points = readings(6)
        let main = try #require(insulinPoints(points, pointsPerValue: 280.0 / 250))

        // The widget drawing the same dose on a plot 338 points tall, which is
        // the mockup the thickness shares were measured against.
        let mockupPlotPoints = 338.0
        let widgetSpan = 200.0
        let widgetPerValue = mockupPlotPoints / widgetSpan
        let widget = WidgetChartView(
            series: GlucoseChartSeries(points: [], updatedAt: points.last!.date),
            unit: .mgdl,
            duration: .threeHours,
            ribbons: doses(points),
            now: points.last!.date
        )
        .ribbonShapes(points, span: widgetSpan, pointsPerValue: widgetPerValue, pointsPerSecond: 0)
        .shapes

        let widgetThickness = try #require(
            widget.filter { $0.kind == "insulin" }
                .flatMap(\.samples)
                .map { abs($0.far - $0.near) * widgetPerValue }
                .max()
        )
        #expect(abs(main - widgetThickness) < 0.5)
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

    /// A trace whose local slope varies from reading to reading, so the
    /// compensation has something to swing on.
    ///
    /// Irregular, and gentle. Two earlier versions of this fixture measured
    /// nothing: a regular zigzag has a central-difference slope of zero at every
    /// sample, and swings of tens of mg/dL pin the compensation at its 2.0 cap
    /// everywhere, which is just as constant. The comb lives in between, where
    /// the compensation is free to move — a few mg/dL between readings, which is
    /// also what a real trace does.
    private func varyingSlope(_ count: Int) -> [GlucoseChartPoint] {
        // Built from a repeating run of steps rather than from a modulus, so the
        // central difference genuinely varies. A modulus gave a difference that
        // was 4 or 5 everywhere, which is as constant as a flat line for this
        // purpose, and the only variation left was at the one-sided ends.
        let steps: [Double] = [0, 1, 3, 6, 3, 1, 0, 0]
        var value: Double = 140
        return (0 ..< count).map { index in
            value += steps[index % steps.count]
            return GlucoseChartPoint(value: value, date: anchor.addingTimeInterval(37 + Double(index) * 300))
        }
    }

    /// Points per second that put five-minute readings this far apart on screen.
    private func pointsPerSecond(spacing: Double) -> Double { spacing / 300 }

    /// Full compensation once readings are far enough apart to show a band, and
    /// none at all when they are on top of each other.
    @Test func theShearFadesWithReadingSpacing() {
        let points = varyingSlope(20)
        let wide = MainChartRibbons.shearFade(
            readings: points,
            pointsPerSecond: pointsPerSecond(spacing: MainChartRibbons.shearFullSpacingPoints)
        )
        let tight = MainChartRibbons.shearFade(readings: points, pointsPerSecond: pointsPerSecond(spacing: 1.28))

        #expect(wide == 1)
        #expect(tight < 0.2)
        // Measured at the 24 h preset: 1.28 pt between readings.
        #expect(abs(tight - 1.28 / MainChartRibbons.shearFullSpacingPoints) < 0.001)
    }

    /// Past the full-compensation spacing the fade stops at one rather than
    /// carrying on up.
    ///
    /// `wide` above sits exactly on the threshold, where clamped and unclamped
    /// give the same answer, so it admits both. The chart goes well past it: at
    /// the fifteen-minute preset readings are tens of points apart, and an
    /// unclamped fade would multiply the compensation several-fold instead of
    /// leaving it at full.
    @Test func theFadeStopsAtFullAndDoesNotAmplify() {
        let far = MainChartRibbons.shearFade(
            readings: varyingSlope(20),
            pointsPerSecond: pointsPerSecond(spacing: MainChartRibbons.shearFullSpacingPoints * 4)
        )
        #expect(far == 1)
    }

    /// The spacing is the typical gap, not the widest one.
    ///
    /// **A dropout is the case the median exists for and the one with no
    /// fixture**: every other trace in this file is a perfect five-minute grid,
    /// where the median, the mean and the maximum are the same number and any
    /// of them would pass. Here eighteen gaps say the readings are crowded and
    /// one forty-minute hole says they are not.
    @Test func theSpacingIsTheTypicalGapAndNotTheWidest() {
        let dense = pointsPerSecond(spacing: 1.28)
        var dates: [Date] = []
        var moment = anchor
        for index in 0 ..< 20 {
            dates.append(moment)
            moment = moment.addingTimeInterval(index == 9 ? 2400 : 300)
        }
        let points = dates.map { GlucoseChartPoint(value: 140, date: $0) }

        // The dropout alone would measure 10.2 pt and fade not at all.
        #expect(2400 * dense / MainChartRibbons.shearFullSpacingPoints > 1)
        #expect(MainChartRibbons.shearFade(readings: points, pointsPerSecond: dense) < 0.2)
    }

    /// A caller that cannot say how wide the plot is gets the drawing it had
    /// before the fade existed, which is the same rule `screenSlope` follows.
    @Test func theShearIsUnfadedWhereSpacingIsUnknown() {
        #expect(MainChartRibbons.shearFade(readings: varyingSlope(20), pointsPerSecond: 0) == 1)
        #expect(MainChartRibbons.shearFade(readings: [], pointsPerSecond: 1) == 1)
    }

    /// The thickness stops swinging from one reading to the next once they are
    /// too close together to show a band.
    ///
    /// This is the comb: at the 24 h preset the compensation sat near its 2.0
    /// cap and changed on every reading, so the ribbon drew as a picket fence
    /// with the trace lost inside it. Measured against the same shapes built
    /// without the fade, which is what shipped first.
    @Test func theRibbonStopsCombingWhenReadingsCrowd() throws {
        let points = varyingSlope(20)
        let perValue = 280.0 / 250
        let perSecond = pointsPerSecond(spacing: 1.28)

        let faded = MainChartRibbons.shapes(
            doses(points), readings: points, now: points.last!.date,
            pointsPerValue: perValue, pointsPerSecond: perSecond
        ).shapes

        // The same call without the fade: the span still comes from the true
        // points-per-value, so only the slope differs.
        let unfaded = WidgetChartView(
            series: GlucoseChartSeries(points: [], updatedAt: points.last!.date),
            unit: .mgdl,
            duration: .threeHours,
            ribbons: doses(points),
            now: points.last!.date
        )
        .ribbonShapes(
            points,
            span: MainChartRibbons.span(pointsPerValue: perValue),
            pointsPerValue: perValue,
            pointsPerSecond: perSecond
        ).shapes

        func maxSwing(_ shapes: [WidgetChartView.RibbonShape]) -> Double {
            shapes.filter { $0.kind == "insulin" }.flatMap { shape -> [Double] in
                let thickness = shape.samples.map { abs($0.far - $0.near) }
                return (0 ..< max(0, thickness.count - 1)).map { abs(thickness[$0 + 1] - thickness[$0]) }
            }.max() ?? 0
        }

        let combed = maxSwing(unfaded)
        #expect(combed > 0, "unfaded swing \(combed), faded \(maxSwing(faded))")
        #expect(maxSwing(faded) < combed / 3, "unfaded swing \(combed), faded \(maxSwing(faded))")
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

    /// A window that opens before the series starts still draws the part that is
    /// stated. Refusing the whole window lost the target line the moment the
    /// render window reached back past the first step, which on a panned chart
    /// is most of the time.
    @Test func theTargetStartsWhereTheSeriesDoesInsideTheWindow() throws {
        let series = target([(3600, 110), (7200, 120)])
        let steps = MainChartRibbons.targetSteps(
            series,
            from: anchor,
            to: anchor.addingTimeInterval(5400)
        )

        #expect(steps.count == 2)
        #expect(steps.first?.date == anchor.addingTimeInterval(3600))
        #expect(steps.first?.mgdl == 110)
        #expect(steps.last?.date == anchor.addingTimeInterval(5400))
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

    /// A step landing exactly on the window's closing edge is drawn.
    ///
    /// The test above reads as though it covers both edges and covers only the
    /// opening one, so `<=` against `<` on the closing edge was invisible. The
    /// two differ in what the line ends at: included, it ends on the new target;
    /// excluded, the old one is carried to the edge instead.
    @Test func aStepOnTheWindowsClosingEdgeIsDrawn() {
        let steps = MainChartRibbons.targetSteps(
            target([(0, 100), (3600, 110)]),
            from: anchor,
            to: anchor.addingTimeInterval(3600)
        )

        #expect(steps.count == 2)
        #expect(steps.last?.date == anchor.addingTimeInterval(3600))
        #expect(steps.last?.mgdl == 110)
    }
}
