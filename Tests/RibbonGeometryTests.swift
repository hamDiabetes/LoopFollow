// LoopFollow
// RibbonGeometryTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What the chart actually draws, asked of the chart.
///
/// **Every test here goes through `WidgetChartView`.** The tests that did this
/// arithmetic in their own bodies all passed against a view that had stopped
/// doing it: deleting the height setting from the view's own formula left 193
/// of 193 green. A test that recomputes what it is checking agrees with
/// anything.
///
/// And they read at **reading times offset from the sample grid**, because the
/// defect this suite keeps meeting is a stretch with no width, which answers
/// only at the instant it was built from.
struct RibbonGeometryTests {
    let anchor = Date(timeIntervalSince1970: 1_757_000_000)

    /// Readings every five minutes, 37 seconds off the cycle boundary.
    private func readings(_ count: Int, from offset: TimeInterval = 37) -> [GlucoseChartPoint] {
        (0 ..< count).map {
            GlucoseChartPoint(value: 120, date: anchor.addingTimeInterval(offset + Double($0) * 300))
        }
    }

    private func view(
        _ ribbons: TreatmentRibbons,
        points: [GlucoseChartPoint],
        fullScaleUnits: Double = 4,
        heightShare: Double = 0.12
    ) -> WidgetChartView {
        WidgetChartView(
            series: GlucoseChartSeries(points: points, updatedAt: points.last?.date ?? anchor),
            unit: .mgdl,
            duration: .threeHours,
            ribbons: ribbons,
            now: points.last?.date ?? anchor,
            insulinFullScaleUnits: fullScaleUnits,
            insulinHeightShare: heightShare
        )
    }

    /// The thickness of the insulin ribbon at its first drawn sample, as a share
    /// of the plot — measured off the shapes the view built.
    private func insulinThickness(
        _ view: WidgetChartView,
        points: [GlucoseChartPoint],
        span: Double = 100
    ) -> Double? {
        let shapes = view.ribbonShapes(points, span: span).shapes.filter { $0.kind == "insulin" }
        guard let sample = shapes.flatMap({ $0.samples }).max(by: { abs($0.near - $0.far) < abs($1.near - $1.far) })
        else { return nil }
        return abs(sample.near - sample.far) / span
    }

    private func insulinRibbons(_ units: Double, cycles: Int = 6) -> TreatmentRibbons {
        let samples = (0 ..< cycles).map {
            InsulinOnBoardSample(date: anchor.addingTimeInterval(Double($0) * 300), units: units)
        }
        let history = InsulinOnBoardHistory(samples: samples, updatedAt: samples.last!.date)
        return TreatmentRibbons(
            insulin: [],
            carbsOnBoard: [],
            rescue: [],
            insulinOnBoard: samples,
            insulinObserved: history.grid()
        )
    }

    /// The height setting scales what is drawn. Delete `* insulinHeightShare`
    /// from the view and this fails; the version of this test that did its own
    /// multiplication did not.
    @Test func theHeightSettingChangesWhatIsDrawn() throws {
        let points = readings(6)
        let ribbons = insulinRibbons(2)

        let short = try #require(insulinThickness(view(ribbons, points: points, heightShare: 0.08), points: points))
        let tall = try #require(insulinThickness(view(ribbons, points: points, heightShare: 0.24), points: points))

        #expect(tall > short * 2.5)
        // Half of full scale at a 12% ceiling is 6% of the plot.
        let middle = try #require(insulinThickness(view(ribbons, points: points, heightShare: 0.12), points: points))
        #expect(abs(middle - 0.06) < 0.005)
    }

    /// The units setting is the other half of the scale, and it is the one
    /// Justin chose. Two units at a four-unit full scale is half height; at an
    /// eight-unit full scale it is a quarter.
    @Test func theFullScaleSettingChangesWhatIsDrawn() throws {
        let points = readings(6)
        let ribbons = insulinRibbons(2)

        let atFour = try #require(insulinThickness(view(ribbons, points: points, fullScaleUnits: 4), points: points))
        let atEight = try #require(insulinThickness(view(ribbons, points: points, fullScaleUnits: 8), points: points))

        #expect(abs(atFour - 0.06) < 0.005)
        #expect(abs(atEight - 0.03) < 0.005)
    }

    /// Above the cap the ribbon stops rather than taking the card.
    @Test func aboveFullScaleTheRibbonHoldsAtItsCeiling() throws {
        let points = readings(6)
        let far = try #require(insulinThickness(view(insulinRibbons(40), points: points), points: points))
        #expect(abs(far - 0.12) < 0.005)
    }

    /// The settings have working fallbacks. Remove the `stored > 0` guard and a
    /// fresh install reads zero, which draws a ribbon of no height at all — a
    /// series that is there, reporting, and invisible.
    @Test func theSettingsFallBackToSomethingDrawable() {
        #expect(LAAppGroupSettings.insulinFullScaleUnits() > 0)
        #expect(LAAppGroupSettings.insulinHeightShare() > 0)
        #expect(LAAppGroupSettings.insulinHeightShare() <= WidgetChartView.Ribbon.maxHeightShare)
    }

    /// The picker cannot offer a height the renderer will silently clamp. Both
    /// numbers are fine today and they are equal today, which is the state where
    /// moving either one quietly stops the setting being the setting.
    @Test func noHeightOptionExceedsTheRenderersOwnClamp() {
        let top = LiveActivitySettingsView.heightOptions.max() ?? 0
        #expect(top > 0)
        #expect(top <= WidgetChartView.Ribbon.maxHeightShare)
    }

    // MARK: - Side, floor and the hairline

    /// Which side the ribbon takes, asked of the view. Flipping the default to
    /// `.above` — the most visually different change available — left the whole
    /// suite green before this existed.
    @Test func theInsulinRibbonHangsBelowTheTrace() throws {
        let points = readings(6)
        let shapes = view(insulinRibbons(2), points: points).ribbonShapes(points, span: 100).shapes
        let sample = try #require(shapes.first { $0.kind == "insulin" }?.samples.first { $0.near != $0.far })
        #expect(sample.far < sample.near, "insulin drew above the trace")
    }

    /// And the placement decides it, rather than the side being baked in.
    @Test func placementDecidesTheSideAndTheFloor() {
        let above = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: true, gap: 0.012, floor: nil)
        let below = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: false, gap: 0.012, floor: nil)
        #expect(above.far > above.near)
        #expect(below.far < below.near)

        #expect(InsulinRibbonPlacement.above.isAbove)
        #expect(!InsulinRibbonPlacement.belowUnclipped.isAbove)
        #expect(InsulinRibbonPlacement.belowClipped.floor(low: 70) == 70)
        #expect(InsulinRibbonPlacement.belowUnclipped.floor(low: 70) == nil)
        #expect(InsulinRibbonPlacement.above.floor(low: 70) == nil)
    }

    /// The clamp is what `.belowClipped` means. Removing it left the suite green
    /// and the case indistinguishable from the one that ships.
    @Test func theClippedPlacementStopsAtItsFloor() {
        let clipped = RibbonGeometry.edges(line: 100, share: 0.5, span: 100, above: false, gap: 0.012, floor: 70)
        #expect(clipped.far == 70)

        let free = RibbonGeometry.edges(line: 100, share: 0.5, span: 100, above: false, gap: 0.012, floor: nil)
        #expect(free.far < 70, "unclipped should run past the floor, which is what Justin asked for")
    }

    /// What ships is unclipped, by his decision from the drawing.
    @Test func whatShipsRunsIntoTheLowSpace() throws {
        let points = readings(6)
        let deep = view(insulinRibbons(4), points: points, heightShare: 0.25)
        let shapes = deep.ribbonShapes(points, span: 100).shapes
        let sample = try #require(shapes.first { $0.kind == "insulin" }?.samples.first { $0.near != $0.far })
        #expect(deep.insulinPlacement.floor(low: 70) == nil)
        #expect(sample.far < sample.near)
    }

    /// Rescue draws no hairline: its absence is the ordinary reading of the
    /// chart rather than a claim. Carbs on board does, because there zero and
    /// unknown are otherwise the same pixels.
    @Test func onlyStateSeriesDrawHairlines() throws {
        let points = readings(6)
        let carbs = (0 ..< 6).map { CarbsOnBoardSample(date: anchor.addingTimeInterval(Double($0) * 300), grams: 0) }
        let history = CarbsOnBoardHistory(samples: carbs, updatedAt: carbs.last!.date)
        let ribbons = TreatmentRibbons(
            insulin: [],
            carbsOnBoard: carbs,
            rescue: [],
            coveredFrom: anchor.addingTimeInterval(-3600),
            carbsObserved: history.grid()
        )

        let baselines = view(ribbons, points: points).ribbonShapes(points, span: 100).baselines
        #expect(baselines.contains { $0.kind == "carbs" }, "carbs on board reporting zero drew no hairline")
        #expect(!baselines.contains { $0.kind == "rescue" }, "rescue drew a hairline")
    }

    // MARK: - Width on a slope

    /// The offset is vertical and what is read is the width across the band, so
    /// on a slope the band has to be widened to read the same. Without the
    /// compensation these two are equal, which is the defect Justin described as
    /// the ribbon losing its width when glucose moves.
    @Test func aSlopedRibbonIsWidenedToReadTheSame() {
        let flat = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: false, gap: 0.012, floor: nil, screenSlope: 0)
        let sloped = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: false, gap: 0.012, floor: nil, screenSlope: 1)

        let flatWidth = abs(flat.near - flat.far)
        let slopedWidth = abs(sloped.near - sloped.far)
        #expect(slopedWidth > flatWidth)

        // At 45 degrees the band reads at cos 45 of its vertical extent, so the
        // vertical extent has to be root two of the flat one for the width
        // across it to match.
        #expect(abs(slopedWidth / flatWidth - 2.0.squareRoot()) < 0.01)

        // Which is the whole point: what the eye measures comes out equal.
        let perpendicular = slopedWidth * (1 / 2.0.squareRoot())
        #expect(abs(perpendicular - flatWidth) < 0.01)
    }

    /// The compensation is capped, and the cap binds on her real data rather
    /// than only in theory: about one lock-screen segment in twenty-three is
    /// steeper than 60 degrees.
    @Test func theCompensationIsCappedAtTwice() {
        // 60 degrees asks for exactly 2.0.
        #expect(abs(RibbonGeometry.widthCompensation(screenSlope: 3.0.squareRoot()) - 2.0) < 0.001)
        // 71 degrees — her 99th percentile — asks for 3.08 and is held at 2.0.
        #expect(RibbonGeometry.widthCompensation(screenSlope: 2.9) == 2.0)
        // And the steepest reading measured, which asks for 3.46.
        #expect(RibbonGeometry.widthCompensation(screenSlope: 3.3) == 2.0)
    }

    /// Monotonic, never below one, never unbounded — the three properties that
    /// keep a compensation from becoming its own defect.
    @Test func theCompensationIsMonotonicAndBounded() {
        var previous = 0.0
        for slope in stride(from: 0.0, through: 8.0, by: 0.1) {
            let factor = RibbonGeometry.widthCompensation(screenSlope: slope)
            #expect(factor >= 1.0)
            #expect(factor <= RibbonGeometry.maxWidthCompensation)
            #expect(factor >= previous)
            previous = factor
        }
    }

    /// Past the cap it is still twice what ships today at that angle, which is
    /// the reason a cap is acceptable rather than a compromise.
    @Test func pastTheCapItIsNeverNarrowerThanBefore() {
        for slope in [1.0, 2.0, 3.0, 4.0, 8.0] {
            let compensated = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: false, gap: 0.012, floor: nil, screenSlope: slope)
            let today = RibbonGeometry.edges(line: 100, share: 0.2, span: 100, above: false, gap: 0.012, floor: nil, screenSlope: 0)
            #expect(abs(compensated.near - compensated.far) >= abs(today.near - today.far))
        }
    }

    // MARK: - A lone carb sample

    /// One cycle's carbs between two gaps drew at no reading time at all: the
    /// stretch ended at the sample's own second, so it answered only a reading
    /// landing on that second, and readings are CGM times.
    @Test func aLoneCarbSampleDrawsAtReadingTimes() throws {
        let sample = CarbsOnBoardSample(date: anchor, grams: 30)
        let history = CarbsOnBoardHistory(samples: [sample], updatedAt: anchor)
        let grid = try #require(history.grid())

        for offset in [1.0, 20.0, 60.0, 120.0, 240.0] {
            let moment = anchor.addingTimeInterval(offset)
            #expect(
                RibbonSampler.carbsOnBoard([sample], at: moment, observed: grid) == .known(30),
                "nothing drawn \(Int(offset)) s after the only sample"
            )
        }
    }

    /// And it reaches the chart: a view built from that one sample draws carb
    /// shapes at the readings around it.
    @Test func aLoneCarbSampleReachesTheChart() throws {
        let sample = CarbsOnBoardSample(date: anchor, grams: 30)
        let history = CarbsOnBoardHistory(samples: [sample], updatedAt: anchor)
        let points = readings(3)
        let ribbons = TreatmentRibbons(
            insulin: [],
            carbsOnBoard: [sample],
            rescue: [],
            carbsObserved: history.grid()
        )

        let shapes = view(ribbons, points: points).ribbonShapes(points, span: 100).shapes
        #expect(shapes.contains { $0.kind == "carbs" })
    }

    /// The same on the wire, where a one-slot run is the ordinary case rather
    /// than the corner: the loop decrements carbs on board almost every cycle,
    /// so the relay's runs never merge.
    @Test func aOneSlotCarbRunFromThePushDrawsAtReadingTimes() throws {
        let json = #"{"anchor":1757000000,"step":300,"values":[100,105,110],"ribbons":{"i":[],"c":[[0,0,30]],"r":[],"o":[[0,0]]}}"#
        let chart = try JSONDecoder().decode(LAChart.self, from: Data(json.utf8))
        let ribbons = try #require(chart.treatmentRibbons())

        for offset in [1.0, 20.0, 60.0, 120.0, 240.0] {
            let moment = anchor.addingTimeInterval(offset)
            #expect(
                RibbonSampler.carbsOnBoard(ribbons.carbsOnBoard, at: moment, observed: ribbons.carbsObserved) == .known(30),
                "nothing drawn \(Int(offset)) s into the only slot"
            )
        }
        // And past the slot it covers, the chart claims nothing rather than zero.
        #expect(RibbonSampler.carbsOnBoard(
            ribbons.carbsOnBoard, at: anchor.addingTimeInterval(600), observed: ribbons.carbsObserved
        ) == .unknown)
    }

    /// A run of one covered reading draws the span it stands for.
    ///
    /// The grid fix made the chart *know* a lone sample; this is what makes it
    /// *draw* one. An area needs two points, so a single covered reading between
    /// two unknowns produced a shape with nothing in it — 21 of 36 readings
    /// answering and an empty chart.
    @Test func aRunOfOneReadingStillDraws() throws {
        let points = readings(5)
        // Carbs known at one reading only: the grid covers that sample and
        // nothing either side of it.
        let sample = CarbsOnBoardSample(date: points[2].date, grams: 30)
        let ribbons = TreatmentRibbons(
            insulin: [],
            carbsOnBoard: [sample],
            rescue: [],
            carbsObserved: ObservedGrid(
                stretches: [ObservedStretch(from: points[2].date, through: points[2].date.addingTimeInterval(60))],
                sampleSpacing: 660
            )
        )

        let shapes = view(ribbons, points: points).ribbonShapes(points, span: 100).shapes.filter { $0.kind == "carbs" }
        let run = try #require(shapes.first)
        #expect(run.samples.count == 2, "a lone reading drew \(run.samples.count) points")
        // And it spans the reading rather than a single instant.
        let width = run.samples[1].date.timeIntervalSince(run.samples[0].date)
        #expect(width > 100 && width <= 300)
        // Both edges carry the same thickness: it is one sample's figure, held
        // across its own span, not a taper into something nobody reported.
        #expect(run.samples[0].far == run.samples[1].far)
    }

    /// One missed cycle is a gap of about 600 seconds and must not break the
    /// series; two is about 900 and must.
    @Test func oneMissedCycleIsBridgedAndTwoIsNot() throws {
        let bridged = CarbsOnBoardHistory(
            samples: [0.0, 300, 900, 1200].map { CarbsOnBoardSample(date: anchor.addingTimeInterval($0), grams: 10) },
            updatedAt: anchor.addingTimeInterval(1200)
        )
        #expect(try #require(bridged.grid()).stretches.count == 1)

        let broken = CarbsOnBoardHistory(
            samples: [0.0, 300, 1200, 1500].map { CarbsOnBoardSample(date: anchor.addingTimeInterval($0), grams: 10) },
            updatedAt: anchor.addingTimeInterval(1500)
        )
        #expect(try #require(broken.grid()).stretches.count == 2)
    }
}
