// LoopFollow
// LAIobTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The insulin-on-board and target series as they arrive from the relay.
///
/// Decoded from JSON rather than built through the memberwise initialiser,
/// because what is being checked is the wire: a test that constructs the struct
/// directly would still pass if the keys were renamed under it.
///
/// **Assert at reading times, never at sample times, and count how many
/// readings drew.** A test written at the slots the JSON above was written with
/// is shaped by the producer's grid, and the seams this series keeps failing on
/// are the consumer's. Two tests here asserted at slot boundaries and passed
/// while the chart drew nothing at all, because a boundary is the one instant
/// the broken version answered.
///
/// Four of these were run against a deliberately broken decoder first, one
/// break each — nulls read as zero, the grid stepped by this app's constant
/// instead of `n`, `s` ignored, an absent series decoded as an empty one — and
/// each break failed its own test and no other.
struct LAIobTests {
    let anchor: Double = 1_757_000_000
    let step: Double = 300

    private func at(_ slot: Double) -> Date {
        Date(timeIntervalSince1970: anchor + slot * step)
    }

    /// A reading time: on the CGM's five minutes, and 37 seconds off the slot
    /// boundary, because that is where readings actually fall. Sampling on the
    /// boundary hides a stretch with no width, which answers only at the instant
    /// of the sample it was built from.
    private func reading(_ index: Int) -> Date {
        Date(timeIntervalSince1970: anchor + 37 + Double(index) * 300)
    }

    /// How many of `count` readings the ribbon has a figure for, the way the
    /// renderer asks.
    private func drawn(_ ribbons: TreatmentRibbons, count: Int) -> Int {
        (0 ..< count).filter { index in
            RibbonSampler.insulinOnBoard(
                ribbons.insulinOnBoard, at: reading(index), observed: ribbons.insulinObserved
            ).value != nil
        }.count
    }

    private func chart(_ body: String) throws -> LAChart {
        let json = """
        {"anchor":\(Int(anchor)),"step":\(Int(step)),"values":[100,105,110],\(body)}
        """
        return try JSONDecoder().decode(LAChart.self, from: Data(json.utf8))
    }

    /// The series is sampled every `n` slots and `n` is on the wire, so the hold
    /// between samples is `n * step` and not any constant this app keeps.
    ///
    /// At three slots that is fifteen minutes, which is wider than every grid
    /// constant here — `publicationInterval` among them. A sampler holding to
    /// one of those would blank the back half of every interval and the ribbon
    /// would come out as stripes.
    @Test func aSpacingWiderThanAnyGridConstantStillDraws() throws {
        let chart = try chart(#""iob":{"s":0,"n":3,"v":[80,60,45]}"#)
        let ribbons = try #require(chart.treatmentRibbons())
        let spacing = 3 * step

        #expect(spacing > InsulinOnBoardHistory.publicationInterval)

        // Just short of the next sample: still the value the loop published.
        let late = at(3).addingTimeInterval(-1)
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: late, observed: ribbons.insulinObserved
        ) == .known(8.0))
    }

    @Test func tenthsComeBackAsUnits() throws {
        let chart = try chart(#""iob":{"s":0,"n":3,"v":[80,60,45]}"#)
        let ribbons = try #require(chart.treatmentRibbons())
        let samples = try #require(ribbons.insulinOnBoard)

        #expect(samples.count == 3)
        #expect(samples[0].date == at(0))
        #expect(samples[1].date == at(3))
        #expect(samples[2].units == 4.5)
    }

    /// A null is the loop not being heard from, which is not a report of zero.
    ///
    /// Read at reading times rather than at slot boundaries: at a boundary this
    /// passed while the chart drew nothing at all, because the surviving runs
    /// were single samples and a stretch of no width answers only its own
    /// instant.
    @Test func aNullDrawsAGapAndNotAZero() throws {
        let chart = try chart(#""iob":{"s":0,"n":3,"v":[80,null,45]}"#)
        let ribbons = try #require(chart.treatmentRibbons())

        #expect(ribbons.insulinOnBoard?.count == 2)
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: reading(0), observed: ribbons.insulinObserved
        ) == .known(8.0))
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: reading(3), observed: ribbons.insulinObserved
        ) == .unknown)
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: reading(6), observed: ribbons.insulinObserved
        ) == .known(4.5))
    }

    /// The null takes its own slots out of the ribbon and nothing else's.
    ///
    /// Counted rather than spot-checked, because the defect this replaces did
    /// not move one reading: it emptied the chart, and every spot check that
    /// happened to sit on a sample still passed.
    @Test func aNullCostsItsOwnSlotsAndNoOthers() throws {
        let whole = try #require(try chart(#""iob":{"s":0,"n":3,"v":[80,60,45]}"#).treatmentRibbons())
        let holed = try #require(try chart(#""iob":{"s":0,"n":3,"v":[80,null,45]}"#).treatmentRibbons())

        #expect(drawn(whole, count: 6) == 6)
        #expect(drawn(holed, count: 6) == 3)
    }

    /// `s` is the coverage bound as well as the start: before it the relay is
    /// saying nothing, and a chart that drew zero there would report an empty
    /// body during the span it has no records for.
    @Test func sBoundsTheSeries() throws {
        let chart = try chart(#""iob":{"s":12,"n":3,"v":[80,60]}"#)
        let ribbons = try #require(chart.treatmentRibbons())

        #expect(ribbons.insulinOnBoard?.first?.date == at(12))
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: at(4), observed: ribbons.insulinObserved
        ) == .unknown)
    }

    /// The relay drops the field when every sample would be null, so a payload
    /// without it is the ordinary case rather than an old producer. Both take
    /// the older ribbon, drawn from doses.
    @Test func aPayloadWithoutIobTakesTheDoseFallback() throws {
        let chart = try chart(#""ribbons":{"i":[[1,125]],"c":[],"r":[]}"#)
        let ribbons = try #require(chart.treatmentRibbons())

        #expect(ribbons.insulinOnBoard == nil)
        #expect(InsulinRibbonSource.choose(insulinOnBoard: ribbons.insulinOnBoard) == .doses)
        #expect(ribbons.insulin?.count == 1)
    }

    /// Insulin still acting on a span with no treatments in it is a real
    /// payload, and it draws.
    @Test func insulinOnBoardAloneStillMakesRibbons() throws {
        let chart = try chart(#""iob":{"s":0,"n":3,"v":[80]}"#)
        let ribbons = try #require(chart.treatmentRibbons())

        #expect(ribbons.insulin == nil)
        // It draws, which counting the samples never asked.
        #expect(drawn(ribbons, count: 3) == 3)
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: reading(0), observed: ribbons.insulinObserved
        ) == .known(8.0))
        // And it stops one spacing on rather than running to the edge.
        #expect(RibbonSampler.insulinOnBoard(
            ribbons.insulinOnBoard, at: reading(4), observed: ribbons.insulinObserved
        ) == .unknown)
    }

    // MARK: - Target

    @Test func theTargetComesBackAsSteps() throws {
        let chart = try chart(#""target":[[0,110,110],[36,100,100]]"#)
        let target = try #require(chart.targetSeries)

        #expect(target.steps.count == 2)
        #expect(target.steps[0].date == at(0))
        #expect(target.steps[1].mgdl == 100)
    }

    /// A profile aiming at a range gets no line, because a line down the middle
    /// of it is a number nobody set.
    @Test func aBandIsRefused() throws {
        let chart = try chart(#""target":[[0,100,120]]"#)
        #expect(chart.targetSeries == nil)
    }

    @Test func noTargetFieldDrawsNoTarget() throws {
        let chart = try chart(#""iob":{"s":0,"n":3,"v":[80]}"#)
        #expect(chart.targetSeries == nil)
    }
}
