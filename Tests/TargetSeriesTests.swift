// LoopFollow
// TargetSeriesTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The target line, which is a handful of changes drawn as a continuous line.
struct TargetSeriesTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date {
        anchor.addingTimeInterval(minutes * 60)
    }

    private func series(_ steps: [(Double, Double)]) -> TargetSeries {
        TargetSeries(steps: steps.map { TargetSeries.Step(date: at($0.0), mgdl: $0.1) })
    }

    /// The rule the whole encoding rests on. Most moments carry no step — that
    /// is the saving — so a lookup by moment finds nothing almost everywhere and
    /// draws a line that blinks in and out.
    @Test func aMomentBetweenStepsTakesTheOneBeforeIt() {
        let target = series([(0, 95), (120, 110)])

        #expect(target.target(at: at(0)) == 95)
        #expect(target.target(at: at(60)) == 95, "an hour after the step, still the step's value")
        #expect(target.target(at: at(119.9)) == 95)
        #expect(target.target(at: at(120)) == 110)
        #expect(target.target(at: at(300)) == 110, "and it holds until something changes it")
    }

    /// Before anything was stated there is no line, rather than the first value
    /// carried backwards into a stretch nobody described.
    @Test func beforeTheFirstStepThereIsNoTarget() {
        let target = series([(60, 95)])

        #expect(target.target(at: at(0)) == nil)
        #expect(target.target(at: at(59.9)) == nil)
        #expect(target.target(at: at(60)) == 95)
    }

    @Test func anEmptySeriesStatesNothingAnywhere() {
        let target = TargetSeries(steps: [])

        #expect(target.isEmpty)
        #expect(target.target(at: at(0)) == nil)
    }

    @Test func stepsArriveInOrderWhateverOrderTheyWereGivenIn() {
        let target = TargetSeries(steps: [
            TargetSeries.Step(date: at(120), mgdl: 110),
            TargetSeries.Step(date: at(0), mgdl: 95),
        ])

        #expect(target.steps.map(\.mgdl) == [95, 110])
        #expect(target.target(at: at(60)) == 95)
    }

    /// A temporary target is two steps: the change, and the change back. The
    /// series has no notion of one; it only knows what the target became.
    @Test func aTemporaryTargetIsJustTwoMoreSteps() {
        let target = series([(0, 95), (30, 140), (90, 95)])

        #expect(target.target(at: at(29)) == 95)
        #expect(target.target(at: at(45)) == 140)
        #expect(target.target(at: at(120)) == 95)
    }

    @Test func valuesComeBackPerMomentIncludingTheNilsBeforeItStarts() {
        let target = series([(60, 95)])

        #expect(target.values(at: [at(0), at(60), at(120)]) == [nil, 95, 95])
    }
}

/// The profile's schedule, expanded into the steps a chart can draw.
struct TargetScheduleTests {
    private let boise = TimeZone(identifier: "America/Boise")!

    private func schedule(_ segments: [(Double, Double)]) -> TargetSchedule? {
        TargetSchedule(low: segments.map { ($0.0 * 3600, $0.1) }, high: segments.map { ($0.0 * 3600, $0.1) })
    }

    private func at(_ hour: Double, day: Int = 17) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = day
        components.hour = Int(hour); components.minute = Int((hour - Double(Int(hour))) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = boise
        return calendar.date(from: components)!
    }

    /// The ordinary daytime case: one segment covers the whole window, so the
    /// series has a single step at its start and the line is flat. A chart with
    /// no step in it is the common case, not a broken one.
    @Test func adaytimeWindowHasOneStepAndNoChanges() throws {
        let target = try #require(schedule([(0, 95), (6, 100), (20, 95)]))
        let series = target.series(from: at(10), to: at(16), timezone: boise)

        #expect(series.steps.count == 1)
        #expect(series.target(at: at(13)) == 100)
    }

    /// An overnight window crosses two boundaries — twenty hundred and
    /// midnight — so it carries two changes.
    @Test func anOvernightWindowCarriesItsBoundaries() throws {
        let target = try #require(schedule([(0, 95), (6, 100), (20, 105)]))
        let series = target.series(from: at(18), to: at(2, day: 18), timezone: boise)

        #expect(series.steps.count == 3, "the opening value, then 20:00 and midnight")
        #expect(series.target(at: at(19)) == 100)
        #expect(series.target(at: at(21)) == 105)
        #expect(series.target(at: at(1, day: 18)) == 95)
    }

    /// Before the day's first segment the one in force is the last of the
    /// previous day.
    @Test func aWindowOpeningAfterMidnightTakesTheEveningsValue() throws {
        let target = try #require(schedule([(6, 100), (20, 105)]))
        let series = target.series(from: at(2), to: at(4), timezone: boise)

        #expect(series.target(at: at(3)) == 105)
    }

    /// A profile aiming at a band is not a line, and this chart draws a line.
    @Test func aRangeProducesNoSchedule() {
        #expect(TargetSchedule(low: [(0, 95)], high: [(0, 110)]) == nil)
        #expect(TargetSchedule(low: [], high: []) == nil)
        #expect(TargetSchedule(low: [(0, 95)], high: [(0, 95), (3600, 95)]) == nil)
    }
}
