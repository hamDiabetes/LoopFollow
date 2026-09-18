// LoopFollow
// CarbsOnBoardObservationTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What an absent carb sample means, which depends entirely on whether anyone
/// was watching that stretch.
///
/// A sender that states the range it observed may stop spelling out its zeros,
/// which is most of what the carb series costs on the wire. That is only safe
/// while both readings of an absence stay separable here.
struct CarbsOnBoardObservationTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval = 300

    private func at(_ slot: Double) -> Date {
        anchor.addingTimeInterval(slot * step)
    }

    private func observed(_ spans: (Double, Double)...) -> ObservedGrid {
        ObservedGrid(
            stretches: spans.map { ObservedStretch(from: at($0.0), through: at($0.1)) },
            sampleSpacing: step
        )
    }

    private func sample(_ slot: Double, _ grams: Double) -> CarbsOnBoardSample {
        CarbsOnBoardSample(date: at(slot), grams: grams)
    }

    // MARK: - Inside the range

    @Test func absenceInsideTheRangeIsAReportedZero() {
        let reading = RibbonSampler.carbsOnBoard([sample(0, 30)], at: at(8), observed: observed((0, 20)))

        #expect(reading == .known(0))
    }

    @Test func absenceBeforeAnySampleButInsideTheRangeIsAlsoZero() {
        let reading = RibbonSampler.carbsOnBoard([sample(10, 30)], at: at(4), observed: observed((0, 20)))

        #expect(reading == .known(0))
    }

    @Test func aSampleInsideTheRangeIsWhatItSays() {
        #expect(RibbonSampler.carbsOnBoard([sample(6, 30)], at: at(6), observed: observed((0, 20))) == .known(30))
    }

    /// The slot after a sample is the series saying zero, not the series saying
    /// nothing, so the twenty minute hold must not reach into it. This is the
    /// half-done state of the change: hold still applied, zeros now implied, and
    /// the two disagreeing about the same slot.
    @Test func theHoldDoesNotReachIntoTheNextSlot() {
        let samples = [sample(6, 30)]
        let range = observed((0, 20))

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(6.5), observed: range) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(7), observed: range) == .known(0))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(9), observed: range) == .known(0))
    }

    // MARK: - Outside it

    /// The defect this rule closes. Observation stops at slot 10 with a zero
    /// reported, and the hold used to carry that zero fifteen minutes into an
    /// outage — and the end of observation is normally the now line, so what it
    /// said was that nothing is on board at this moment.
    @Test func aFigureDoesNotOutliveTheStretchItWasReportedIn() {
        let samples = [sample(8, 30), sample(10, 0)]
        let grid = observed((0, 10))

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(10), observed: grid) == .known(0))
        for slot in [11.0, 12.0, 13.0, 14.0] {
            #expect(RibbonSampler.carbsOnBoard(samples, at: at(slot), observed: grid) == .unknown)
        }
    }

    /// The same at the other end of a run: a figure still climbing when the
    /// reports stop does not stand for the next twenty minutes either.
    @Test func neitherDoesAFigureThatWasStillOnBoard() {
        let samples = [sample(10, 30)]
        let grid = observed((0, 10))

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(10), observed: grid) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(11), observed: grid) == .unknown)
    }

    /// Observation breaks into stretches, and the break between two of them is
    /// a pump comms outage rather than a quiet hour. Nothing is carried across
    /// it — not from the stretch before, and not into the stretch after.
    @Test func nothingIsCarriedAcrossTheGapBetweenTwoStretches() {
        let samples = [sample(4, 30), sample(20, 12)]
        let grid = observed((0, 6), (18, 24))

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(5), observed: grid) == .known(0))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(10), observed: grid) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(19), observed: grid) == .known(0))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(20), observed: grid) == .known(12))
    }

    @Test func absenceOutsideTheRangeStaysUnknown() {
        let samples = [sample(10, 30)]
        let range = observed((8, 20))

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(2), observed: range) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(30), observed: range) == .unknown)
    }

    /// A grid that states nothing about a moment is not a grid that licenses a
    /// guess about it. Where the series has no stated stretches at all, the hold
    /// still governs — that is the store's path, tested below — but an empty
    /// list of stretches is a producer saying it watched nothing.
    @Test func aGridWithNoStretchesObservesNothing() {
        let samples = [sample(10, 30)]
        let grid = ObservedGrid(stretches: [], sampleSpacing: step)

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(10), observed: grid) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(11), observed: grid) == .unknown)
    }

    /// The path that gathers the series itself states no range, and nothing
    /// about it changes: samples arrive per cycle rather than on a grid, so an
    /// absence there really is nobody listening.
    @Test func withNoRangeAtAllTheOldRulesHold() {
        let samples = [sample(10, 30)]

        #expect(RibbonSampler.carbsOnBoard(samples, at: at(11)) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(14)) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(samples, at: at(2)) == .unknown)
    }

    @Test func aSeriesThatNeverLandedIsUnknownWhateverTheRangeSays() {
        #expect(RibbonSampler.carbsOnBoard(nil, at: at(5), observed: observed((0, 20))) == .unknown)
    }

    // MARK: - Saying that zero is known

    /// A baseline is drawn wherever the chart has a value, and a reported zero
    /// is a value. Without it, an observed stretch of zero and an unobserved
    /// stretch are the same absence of pixels — which is the confusion that
    /// produced a false bug report, and then fooled the person who had seeded
    /// the data.
    @Test func aBaselineIsEmittedForObservedZeroAndNotForUnobserved() {
        let known = [true, true, true, false, false, true]
        let runs = RibbonBaseline.runs(known: known, gapAfter: Array(repeating: false, count: known.count))

        #expect(runs == [0 ... 2, 5 ... 5])
    }

    /// And it breaks where the readings break, for the reason the ribbons do: a
    /// mark drawn across a dropout claims a continuity the glucose series
    /// denies.
    @Test func aBaselineBreaksAtASensorDropout() {
        let known = [true, true, true, true]
        var gapAfter = Array(repeating: false, count: known.count)
        gapAfter[1] = true

        #expect(RibbonBaseline.runs(known: known, gapAfter: gapAfter) == [0 ... 1, 2 ... 3])
    }

    @Test func nothingKnownIsNothingDrawn() {
        #expect(RibbonBaseline.runs(known: [false, false], gapAfter: [false, false]).isEmpty)
        #expect(RibbonBaseline.runs(known: [], gapAfter: []).isEmpty)
    }

    // MARK: - Which range

    /// The window bound and the carb series' own range are different facts, and
    /// only the second licenses a zero. Device status coverage is the narrower
    /// of the two for a day after a relay restart, so reading zeros out of the
    /// window bound would assert them across exactly the stretch this series had
    /// not seen.
    @Test func theWindowBoundDoesNotLicenseAZero() {
        let ribbons = TreatmentRibbons(
            insulin: [],
            carbsOnBoard: [sample(20, 30)],
            rescue: [],
            coveredFrom: at(0),
            carbsObserved: observed((18, 24))
        )

        // Inside the window the push describes, outside what the carb series saw.
        #expect(RibbonSampler.carbsOnBoard(ribbons.carbsOnBoard, at: at(4), observed: ribbons.carbsObserved) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(ribbons.carbsOnBoard, at: at(22), observed: ribbons.carbsObserved) == .known(0))
        #expect(ribbons.carbsObserved?.stretch(containing: at(4)) == nil)
    }

    @Test func theRangeSurvivesBeingEncodedAndDecoded() throws {
        let ribbons = TreatmentRibbons(
            insulin: [],
            carbsOnBoard: [sample(2, 12)],
            rescue: [],
            carbsObserved: observed((0, 10))
        )
        let back = try JSONDecoder().decode(TreatmentRibbons.self, from: JSONEncoder().encode(ribbons))

        #expect(back.carbsObserved == ribbons.carbsObserved)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(5), observed: back.carbsObserved) == .known(0))
    }

    @Test func aPayloadWithNoRangeDecodesWithout() throws {
        let ribbons = TreatmentRibbons(insulin: [], carbsOnBoard: [sample(2, 12)], rescue: [])
        let back = try JSONDecoder().decode(TreatmentRibbons.self, from: JSONEncoder().encode(ribbons))

        #expect(back.carbsObserved == nil)
    }
}
