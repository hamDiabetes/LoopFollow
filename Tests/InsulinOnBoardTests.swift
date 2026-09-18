// LoopFollow
// InsulinOnBoardTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Insulin on board as a standing quantity, which is what the ribbon draws now.
struct InsulinOnBoardTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private let cadence = InsulinOnBoardHistory.publicationInterval

    private func at(_ cycles: Double) -> Date {
        anchor.addingTimeInterval(cycles * cadence)
    }

    private func history(_ cycles: [Double], units: Double = 2.5) -> InsulinOnBoardHistory {
        let samples = cycles.map { InsulinOnBoardSample(date: at($0), units: units) }
        return InsulinOnBoardHistory(samples: samples, updatedAt: samples.last?.date ?? anchor)
    }

    // MARK: - The tri-state

    /// The same rule the carb series runs on: inside a stretch an absence is a
    /// reported zero, outside it nobody was listening.
    @Test func absenceInsideAStretchIsZeroAndOutsideIsUnknown() throws {
        let store = history([0, 1, 2])
        let grid = try #require(store.grid())

        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(1), observed: grid) == .known(2.5))
        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(4), observed: grid) == .unknown)
        #expect(RibbonSampler.insulinOnBoard(nil, at: at(1), observed: grid) == .unknown)
    }

    @Test func aHoleReadsAsUnknownRatherThanAsTheFigureBeforeIt() throws {
        let store = history([0, 1, 8, 9])
        let grid = try #require(store.grid())

        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(4), observed: grid) == .unknown)
        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(8), observed: grid) == .known(2.5))
    }

    // MARK: - Negative insulin on board

    /// oref reports a negative figure when less insulin is acting than the
    /// profile's basal would have delivered — 87 of 2000 real samples, to
    /// −0.17 U. It is a known quantity, not a missing one, so it clamps to zero
    /// and is never dropped: a dropped sample reads as unknown, and unknown is
    /// a different claim from none.
    @Test func aNegativeFigureIsAZeroAndNotAHole() throws {
        let samples = [
            InsulinOnBoardSample(date: at(0), units: 1.2),
            InsulinOnBoardSample(date: at(1), units: -0.17),
            InsulinOnBoardSample(date: at(2), units: 0.4),
        ]
        let store = InsulinOnBoardHistory(samples: samples, updatedAt: at(2))
        let grid = try #require(store.grid())

        #expect(store.samples.count == 3, "the negative cycle is kept")
        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(1), observed: grid) == .known(0))
        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(1), observed: grid) != .unknown)
    }

    // MARK: - Which producer the ribbon comes from

    /// Nil is a producer that does not send the series; empty is a producer
    /// that does, reporting none. The first falls back to doses, the second
    /// draws nothing — and answering "no insulin on board" with a row of dose
    /// marks is the chart stating something false in place of saying nothing.
    @Test func nilFallsBackToDosesAndEmptyDoesNot() {
        #expect(InsulinRibbonSource.choose(insulinOnBoard: nil) == .doses)
        #expect(InsulinRibbonSource.choose(insulinOnBoard: []) == .onBoard)
        #expect(InsulinRibbonSource.choose(insulinOnBoard: [InsulinOnBoardSample(date: at(0), units: 0)]) == .onBoard)
        #expect(InsulinRibbonSource.choose(insulinOnBoard: [InsulinOnBoardSample(date: at(0), units: 2.5)]) == .onBoard)
    }

    /// The Live Activity's case as it stands: the relay sends doses and no
    /// insulin-on-board series, so that surface draws the older ribbon rather
    /// than losing the ribbon altogether.
    @Test func aPayloadWithoutTheSeriesStillHasAnInsulinRibbon() {
        let ribbons = TreatmentRibbons(
            insulin: [TreatmentEvent(date: at(0), amount: 1.2)],
            carbsOnBoard: nil,
            rescue: []
        )

        #expect(ribbons.insulinOnBoard == nil)
        #expect(InsulinRibbonSource.choose(insulinOnBoard: ribbons.insulinOnBoard) == .doses)
        #expect((RibbonSampler.insulin(ribbons.insulin, at: at(0), window: 300) ?? 0) > 0)
    }

    /// And a person with none on board is drawn as none, not as their doses.
    @Test func aReportedZeroDrawsNothingRatherThanDoses() throws {
        let store = history([0, 1, 2], units: 0)
        let grid = try #require(store.grid())

        #expect(InsulinRibbonSource.choose(insulinOnBoard: store.samples) == .onBoard)
        #expect(RibbonSampler.insulinOnBoard(store.samples, at: at(1), observed: grid) == .known(0))
    }

    // MARK: - The scale

    /// Full height is a number somebody set, not one derived from the loop.
    /// What it is scaled to has to hold still: a figure that moved through the
    /// day redrew a stretch already looked at at a different thickness.
    @Test func theScaleIsTheSettingAndNothingElse() {
        #expect(InsulinOnBoard.share(of: 4, fullScaleUnits: 4) == 1.0)
        #expect(InsulinOnBoard.share(of: 2, fullScaleUnits: 4) == 0.5)
        #expect(InsulinOnBoard.share(of: 0, fullScaleUnits: 4) == 0)
    }

    /// Above the cap the ribbon stops growing rather than taking the card: it
    /// says "at least this much", and the figure beside the chart says the rest.
    @Test func aFigureBeyondFullHeightIsHeldThere() {
        #expect(InsulinOnBoard.share(of: 30, fullScaleUnits: 4) == 1.0)
    }

    /// Justin's two numbers, as the heights they draw. At four units and a
    /// twelfth of the plot, 0.7 U is a shade over the glucose trace's own
    /// width rather than three times it, and 3 U is a ribbon rather than a
    /// quarter of the card.
    @Test func theNumbersHeGaveDrawTheHeightsHeAskedFor() {
        let plot = 160.0
        let share = InsulinOnBoard.defaultHeightShare
        let full = InsulinOnBoard.defaultFullScaleUnits

        let low = InsulinOnBoard.share(of: 0.7, fullScaleUnits: full) * share * plot
        let high = InsulinOnBoard.share(of: 3.0, fullScaleUnits: full) * share * plot
        #expect(low > 3.0 && low < 4.0)
        #expect(high > 13.0 && high < 15.0)
    }

    @Test func aNonsenseFullScaleDrawsNothingRatherThanDividingByIt() {
        #expect(InsulinOnBoard.share(of: 2, fullScaleUnits: 0) == 0)
        #expect(InsulinOnBoard.share(of: 2, fullScaleUnits: -5) == 0)
    }
}
