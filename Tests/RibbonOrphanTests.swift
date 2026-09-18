// LoopFollow
// RibbonOrphanTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Treatments the ribbons cannot carry, and the markers that stand in for them.
///
/// A treatment drawn nowhere looks exactly like a treatment that did not
/// happen, and the marker is the only thing between those two.
struct RibbonOrphanTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)
    private let step: TimeInterval = 300
    private let window: TimeInterval = 300

    private func at(_ slot: Double) -> Date {
        anchor.addingTimeInterval(slot * step)
    }

    private func readings(_ slots: [Double]) -> [Date] {
        slots.map(at)
    }

    // MARK: - Insulin

    /// The case the two mechanisms disagreed over: a bolus on a slot whose
    /// reading is missing, with the next reading one slot later, exactly where
    /// the bolus stops counting. The ribbon draws nothing, so the marker must.
    @Test func aBolusOnASlotWithNoReadingIsNotDrawnAndIsMarked() {
        let bolus = TreatmentEvent(date: at(10), amount: 1.5)
        let seen = readings([8, 9, 11, 12])

        for reading in seen {
            #expect(RibbonSampler.insulin([bolus], at: reading, window: window) == 0)
        }
        #expect(RibbonOrphans.insulin([bolus], readings: seen, window: window) == [at(10)])
    }

    /// And the ordinary case stays ordinary: a reading inside the window the
    /// bolus is counted over carries it, so no marker.
    @Test func aBolusTheRibbonCanCarryIsNotMarked() {
        let bolus = TreatmentEvent(date: at(10), amount: 1.5)
        let seen = readings([10, 11])

        #expect(RibbonSampler.insulin([bolus], at: at(10), window: window) == 1.5)
        #expect(RibbonOrphans.insulin([bolus], readings: seen, window: window).isEmpty)
    }

    /// A reading at the instant the window closes is the boundary the two
    /// conventions differed on, and it must be read the same way in both: the
    /// sampler counts nothing there, so the treatment is orphaned.
    @Test func theInstantTheWindowClosesCountsForNeither() {
        let bolus = TreatmentEvent(date: at(10), amount: 0.4)
        let closing = at(11)

        #expect(RibbonSampler.insulin([bolus], at: closing, window: window) == 0)
        #expect(RibbonOrphans.insulin([bolus], readings: [closing], window: window) == [at(10)])
    }

    @Test func aSeriesThatNeverLandedHasNoOrphans() {
        #expect(RibbonOrphans.insulin(nil, readings: readings([1, 2]), window: window).isEmpty)
        #expect(RibbonOrphans.rescue(nil, readings: readings([1, 2])).isEmpty)
    }

    // MARK: - Rescue

    /// The same boundary on the rescue series, where the span is the absorption:
    /// fully absorbed, the entry contributes nothing, so a reading only there
    /// leaves it undrawn.
    @Test func aRescueEntryAbsorbedByItsOnlyReadingIsMarked() {
        let entry = TreatmentEvent(date: at(0), amount: 6)
        // The entry's own duration, which now depends on how much was given.
        let fullyAbsorbed = at(0).addingTimeInterval(RescueAbsorption.duration(ofGrams: 6, rate: nil))

        #expect(RibbonSampler.rescue([entry], at: fullyAbsorbed) == 0)
        #expect(RibbonOrphans.rescue([entry], readings: [fullyAbsorbed]) == [at(0)])
    }

    @Test func aRescueEntryWithAReadingMidAbsorptionIsNotMarked() {
        let entry = TreatmentEvent(date: at(0), amount: 6)
        let midway = at(0).addingTimeInterval(RescueAbsorption.duration(ofGrams: 6, rate: nil) / 2)

        #expect(RibbonOrphans.rescue([entry], readings: [midway]).isEmpty)
    }

    // MARK: - The property that covers the rescue series

    /// Every rescue entry is drawn as something: thickness at some reading, or
    /// a marker. Never neither.
    ///
    /// This series gets a property where the others get a comparison, because it
    /// has no second number to disagree with: rescue carbs are reported by
    /// nothing else on the card and never will be, which is the point of the
    /// series. The only check available is against the model.
    ///
    /// **What this does not cover.** It is the consumer side only. An entry the
    /// chart never receives — dropped in the relay's trim, filtered out by a
    /// query, lost before it reaches `TreatmentRibbons` — satisfies this
    /// trivially, because a series of zero entries has nothing to fail on. It
    /// says nothing about whether the right entries arrived.
    ///
    /// **What it is for.** The property holds by construction while drawing and
    /// marking answer to one authority, which is how they were joined after they
    /// disagreed over a single instant and dropped a bolus between them. It
    /// fails the moment someone restates either span independently. That is a
    /// regression guard against the shape, not coverage of the model.
    @Test func everyRescueEntryIsDrawnAsSomething() {
        // Readings on a five-minute grid with two dropouts in it, and entries
        // walked across every alignment with the grid, the dropouts and the ends
        // of their own absorption.
        let grid = (0 ... 60).map(Double.init).filter { !(12 ... 20).contains($0) && !(35 ... 38).contains($0) }
        let seen = readings(grid)

        for offset in stride(from: 0.0, through: 60.0, by: 0.25) {
            let entry = TreatmentEvent(date: at(offset), amount: 6)
            let drawn = seen.contains { (RibbonSampler.rescue([entry], at: $0) ?? 0) > 0 }
            let marked = RibbonOrphans.rescue([entry], readings: seen).contains(entry.date)

            #expect(drawn != marked, "entry at \(offset) was drawn: \(drawn), marked: \(marked)")
        }
    }

    /// The same for insulin, where a run total is read off the events and a
    /// bolus drawn nowhere takes its units out of a figure that is still shown.
    @Test func everyBolusIsDrawnAsSomething() {
        let grid = (0 ... 30).map(Double.init).filter { $0 != 10 && !(18 ... 22).contains($0) }
        let seen = readings(grid)

        for offset in stride(from: 0.0, through: 30.0, by: 0.25) {
            let bolus = TreatmentEvent(date: at(offset), amount: 0.25)
            let drawn = seen.contains { (RibbonSampler.insulin([bolus], at: $0, window: window) ?? 0) > 0 }
            let marked = RibbonOrphans.insulin([bolus], readings: seen, window: window).contains(bolus.date)

            #expect(drawn != marked, "bolus at \(offset) was drawn: \(drawn), marked: \(marked)")
        }
    }

    // MARK: - Carbs on board gets no markers

    /// An observation is not an event, so a gap in the carb series is a gap.
    ///
    /// This used to draw one marker per undrawable stretch, and in a sparse
    /// store that was eleven marks across four hours in which nothing happened
    /// — the chart inventing treatments out of the moments nobody was looking.
    @Test func carbsOnBoardHasNoOrphanRule() {
        // The type offers no way to ask, which is the guarantee: there is no
        // `RibbonOrphans.carbs` to call.
        let events = [TreatmentEvent(date: at(10), amount: 1.5)]

        #expect(RibbonOrphans.insulin(events, readings: [], window: window) == [at(10)])
        #expect(RibbonOrphans.rescue(events, readings: []) == [at(10)])
    }
}
