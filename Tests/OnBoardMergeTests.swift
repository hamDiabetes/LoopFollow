// LoopFollow
// OnBoardMergeTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What happens when two processes write one file.
///
/// The app appends on its poll and the widget appends on its timeline run, and
/// nothing orders those against each other. The rule that makes that safe is
/// that an append adds rather than replaces: a lost race costs one sample that
/// the next cycle adds again, where a replace would put back a copy missing
/// whatever arrived in between — truncating history, and looking exactly like
/// the sparse store the second writer exists to prevent.
struct OnBoardMergeTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date {
        anchor.addingTimeInterval(minutes * 60)
    }

    private func carbs(_ minutes: [Double]) -> [CarbsOnBoardSample] {
        minutes.map { CarbsOnBoardSample(date: at($0), grams: 20) }
    }

    /// The case that matters: a writer holding an older copy adds its sample and
    /// keeps everything that arrived while it was holding it.
    @Test func aStaleWriterKeepsWhatArrivedWhileItWasHolding() throws {
        // The widget read this before the app appended twice more.
        let stale = carbs([0, 5])
        let current = carbs([0, 5, 10, 15])
        let late = CarbsOnBoardSample(date: at(20), grams: 20)

        // Merging happens against the file as it stands, not against the stale
        // copy, which is what the coordinated read inside the write gives it.
        let merged = try #require(OnBoardMerge.merging(current, with: late))

        #expect(merged.map(\.date) == [at(0), at(5), at(10), at(15), at(20)])
        #expect(merged.count > stale.count + 1, "nothing from the meantime is dropped")
    }

    /// Out of order is not a special case: a sample older than the newest is
    /// added where it belongs rather than refused, because with two writers
    /// there is no reason the later arrival is the later cycle.
    @Test func anOlderSampleIsAddedRatherThanRefused() throws {
        let stored = carbs([0, 10])
        let merged = try #require(OnBoardMerge.merging(stored, with: CarbsOnBoardSample(date: at(5), grams: 20)))

        #expect(merged.map(\.date) == [at(0), at(5), at(10)])
    }

    /// The same cycle arriving twice — which is the ordinary case, since both
    /// writers read the same newest record — changes nothing and rewrites
    /// nothing.
    @Test func theSameCycleTwiceIsNotAChange() {
        let stored = carbs([0, 5])

        #expect(OnBoardMerge.merging(stored, with: CarbsOnBoardSample(date: at(5), grams: 20)) == nil)
        #expect(OnBoardMerge.merging(stored, with: CarbsOnBoardSample(date: at(5), grams: 99)) == nil)
    }

    @Test func insulinMergesOnTheSameTerms() throws {
        let stored = [InsulinOnBoardSample(date: at(0), units: 1.2), InsulinOnBoardSample(date: at(10), units: 0.8)]
        let merged = try #require(OnBoardMerge.merging(stored, with: InsulinOnBoardSample(date: at(5), units: 1.0)))

        #expect(merged.map(\.units) == [1.2, 1.0, 0.8])
        #expect(OnBoardMerge.merging(stored, with: InsulinOnBoardSample(date: at(10), units: 0.8)) == nil)
    }
}
