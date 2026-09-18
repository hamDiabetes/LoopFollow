// LoopFollow
// CarbsOnBoardGridTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The grid the store states about its own samples, and what the chart reads
/// out of it.
///
/// Without one the widget falls through to the hold and carries the last figure
/// for four cycles after the loop goes quiet, while the lock screen has already
/// stopped claiming it. Two surfaces answering one question differently is the
/// thing that keeps turning out to be a wrong model.
struct CarbsOnBoardGridTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private let cadence = CarbsOnBoardHistory.publicationInterval

    private func at(_ cycles: Double) -> Date {
        anchor.addingTimeInterval(cycles * cadence)
    }

    private func history(_ cycles: [Double], grams: Double = 30) -> CarbsOnBoardHistory {
        let samples = cycles.map { CarbsOnBoardSample(date: at($0), grams: grams) }
        return CarbsOnBoardHistory(samples: samples, updatedAt: samples.last?.date ?? anchor)
    }

    @Test func anUnbrokenRunOfCyclesIsOneStretch() throws {
        let grid = try #require(history([0, 1, 2, 3]).grid())

        #expect(grid.stretches.count == 1)
        #expect(grid.stretches.first?.from == at(0))
        // Through the last sample's hold, not to its timestamp: a stretch is
        // read by asking whether a reading falls inside it, and a reading never
        // lands on a sample's second.
        #expect(grid.stretches.first?.through == at(3).addingTimeInterval(cadence - 1))
    }

    /// The app suspended for a while leaves a hole, and the hole is a stretch
    /// nobody heard rather than a stretch with nothing on board.
    @Test func aGapLongerThanTheCadenceBreaksTheStretch() throws {
        let grid = try #require(history([0, 1, 8, 9]).grid())

        #expect(grid.stretches.count == 2)
        #expect(grid.stretches.map(\.through) == [
            at(1).addingTimeInterval(cadence - 1),
            at(9).addingTimeInterval(cadence - 1),
        ])
    }

    @Test func anEmptyStoreStatesNoGrid() {
        #expect(CarbsOnBoardHistory(samples: [], updatedAt: anchor).grid() == nil)
    }

    /// One sample is a stretch with width, not an instant.
    ///
    /// It used to be `from == through`, which answers only a reading landing on
    /// that exact second — so a lone cycle between two gaps drew nothing at all,
    /// on a chart that had the figure and was told where it was watched.
    @Test func oneSampleIsAStretchOfItsOwn() throws {
        let grid = try #require(history([4]).grid())

        #expect(grid.stretches.count == 1)
        #expect(grid.stretches.first?.from == at(4))
        #expect(grid.stretches.first?.through == at(4).addingTimeInterval(cadence - 1))
        #expect(RibbonSampler.carbsOnBoard(
            history([4]).samples, at: at(4).addingTimeInterval(37), observed: grid
        ) == .known(30))
    }

    // MARK: - The property, on clocks that do not line up

    /// Inside a stretch, no moment reports zero while a later sample carries a
    /// figure.
    ///
    /// Swept across clock alignments rather than on one grid, because the loop's
    /// cycles and the CGM's readings are independent clocks and the rule that
    /// reads an absence as a zero was reasoned about a payload where they are
    /// the same five minute slots. It holds by construction — a stretch is built
    /// so consecutive samples are at most a step apart — and the point of the
    /// test is that the construction is what holds it, so a change to how
    /// stretches are built has something to fail against.
    @Test func noMomentInsideAStretchReportsZeroWithCarbsEitherSide() throws {
        for offsetSeconds in stride(from: 0.0, through: 600.0, by: 17.0) {
            let store = history([0, 1, 2, 3, 4])
            let grid = try #require(store.grid())
            let first = try #require(store.samples.first?.date)
            let last = try #require(store.samples.last?.date)

            var moment = first.addingTimeInterval(offsetSeconds.truncatingRemainder(dividingBy: cadence))
            while moment <= last {
                let reading = RibbonSampler.carbsOnBoard(store.samples, at: moment, observed: grid)
                if store.samples.contains(where: { $0.date > moment && $0.grams > 0 }) {
                    #expect(reading != .known(0), "offset \(offsetSeconds)s reported zero with carbs still to come")
                }
                moment = moment.addingTimeInterval(cadence)
            }
        }
    }

    /// A moment between two cycles reports the figure still standing, on any
    /// clock.
    @Test func aMomentBetweenTwoCyclesHoldsTheFigure() throws {
        let store = history([0, 1])
        let grid = try #require(store.grid())

        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(0.5), observed: grid) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(0.99), observed: grid) == .known(30))
    }

    // MARK: - The grid and the samples have to agree

    /// A zero nobody published, and the only way this path can make one.
    ///
    /// The sampler answers a moment inside an observed stretch with a reported
    /// zero when it finds no sample at or before it within that stretch. That
    /// cannot happen while the grid is derived from the samples being sampled —
    /// and it happens immediately when a caller trims the samples and keeps the
    /// grid from the untrimmed store.
    @Test func aGridThatOutrunsItsSamplesInventsAZero() throws {
        let store = history([0, 1, 2, 3, 4])
        let wholeGrid = try #require(store.grid())
        let trimmed = Array(store.samples.suffix(2))

        // As it must be: the grid built from what is handed over.
        let ownGrid = try #require(CarbsOnBoardHistory(samples: trimmed, updatedAt: at(4)).grid())
        #expect(RibbonSampler.carbsOnBoard(trimmed, at: at(3.5), observed: ownGrid) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(trimmed, at: at(1), observed: ownGrid) == .unknown)

        // And the mismatch, which reports a figure the loop never published.
        #expect(RibbonSampler.carbsOnBoard(trimmed, at: at(1), observed: wholeGrid) == .known(0))
    }

    // MARK: - What the chart then reads

    /// The leading edge, which is the reason for the grid. The stretch ends at
    /// the last figure the store holds, and the chart stops claiming one there
    /// — the same answer the lock screen gives, rather than the twenty minute
    /// hold carrying it for four more cycles.
    @Test func theLastFigureDoesNotOutliveItsStretch() throws {
        let store = history([0, 1, 2])
        let grid = try #require(store.grid())

        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(2), observed: grid) == .known(30))
        // Held for its own publication interval — the figure is what the loop
        // last said and it stands until the next cycle would have arrived — and
        // then nothing.
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(2.5), observed: grid) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(3.1), observed: grid) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(4), observed: grid) == .unknown)

        // What this surface did before the grid, and what the lock screen had
        // already stopped doing: hold the last figure for a fixed span with
        // nothing saying whether anybody was still watching. Read without a
        // grid, that hold is all there is.
        let heldWithoutAGrid = at(2).addingTimeInterval(RibbonSampler.carbsOnBoardMaxHold - 1)
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: heldWithoutAGrid) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: heldWithoutAGrid, observed: grid) == .unknown)
    }

    /// Inside a hole the chart says nothing rather than holding the figure from
    /// before it.
    @Test func aHoleReadsAsUnknownRatherThanAsTheFigureBeforeIt() throws {
        let store = history([0, 1, 8, 9])
        let grid = try #require(store.grid())

        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(4), observed: grid) == .unknown)
        #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(8), observed: grid) == .known(30))
    }

    /// And the grid invents no zeros of its own: a stretch is built from the
    /// samples, so there is never a slot inside one that the store did not fill.
    @Test func theGridImpliesNoZerosOnThisPath() throws {
        let store = history([0, 1, 2])
        let grid = try #require(store.grid())

        for cycle in [0.0, 1.0, 2.0] {
            #expect(RibbonSampler.carbsOnBoard(store.samples, at: at(cycle), observed: grid) == .known(30))
        }
    }
}
