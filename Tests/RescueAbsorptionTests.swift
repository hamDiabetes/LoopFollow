// LoopFollow
// RescueAbsorptionTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What this chart believes happens to a rescue carb.
///
/// It can never be checked against the loop: a rescue note carries no `carbs`
/// field, so nothing downstream counts it, which is the safety property that
/// keeps it out of dosing. That is the argument for anchoring it to a number
/// Nightscout publishes rather than to one we chose.
struct RescueAbsorptionTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ grams: Double) -> TreatmentEvent {
        TreatmentEvent(date: anchor, amount: grams)
    }

    private func after(_ minutes: Double) -> Date {
        anchor.addingTimeInterval(minutes * 60)
    }

    // MARK: - Duration follows the amount

    /// The fault this replaces: six grams and sixty cleared in the same seventy
    /// minutes, because the duration was two constants that did not consult the
    /// amount.
    @Test func moreCarbsTakeLonger() {
        let small = RescueAbsorption.duration(ofGrams: 6, rate: 21)
        let large = RescueAbsorption.duration(ofGrams: 60, rate: 21)

        #expect(large > small)
        let smallDecay = small - RescueAbsorption.onset
        let largeDecay = large - RescueAbsorption.onset
        #expect(abs(largeDecay / smallDecay - 10) < 0.001, "ten times the carbs, ten times the decay, at one rate")
    }

    /// Anchored to the profile's own `carbs_hr`, which is 21 g/hr for this
    /// family. Six grams then take **25 minutes** end to end: an 8 minute onset
    /// ramp and 17 minutes of decay. The decay alone is not the duration, and
    /// quoting it as one is how a figure half the size of the real one gets
    /// built on later.
    @Test func theRateIsGramsPerHour() {
        let decay = RescueAbsorption.duration(ofGrams: 21, rate: 21) - RescueAbsorption.onset

        #expect(abs(decay - 3600) < 1, "a rate of 21 g/hr clears 21 g in an hour")
    }

    @Test func aFasterRateClearsSooner() {
        #expect(RescueAbsorption.duration(ofGrams: 18, rate: 40) < RescueAbsorption.duration(ofGrams: 18, rate: 21))
    }

    /// A rate nobody supplied is a documented default rather than a division by
    /// zero or a ribbon that never ends.
    @Test func anAbsentOrNonsenseRateFallsBackToTheStatedDefault() {
        let fallback = RescueAbsorption.duration(ofGrams: 12, rate: nil)

        #expect(fallback == RescueAbsorption.duration(ofGrams: 12, rate: RescueAbsorption.fallbackGramsPerHour))
        #expect(RescueAbsorption.duration(ofGrams: 12, rate: 0) == fallback)
        #expect(RescueAbsorption.duration(ofGrams: 12, rate: -5) == fallback)
    }

    // MARK: - The curve

    @Test func theOnsetRampStillRises() {
        let six = entry(6)

        #expect(RescueAbsorption.remaining(of: six, at: anchor, rate: 21) == 0)
        #expect(RescueAbsorption.remaining(of: six, at: after(4), rate: 21) > 0)
        #expect(RescueAbsorption.remaining(of: six, at: after(8), rate: 21) == 6)
    }

    @Test func itReachesZeroAtItsOwnDurationAndStaysThere() {
        let six = entry(6)
        let seconds = RescueAbsorption.duration(ofGrams: 6, rate: 21)

        #expect(RescueAbsorption.remaining(of: six, at: anchor.addingTimeInterval(seconds - 60), rate: 21) > 0)
        #expect(RescueAbsorption.remaining(of: six, at: anchor.addingTimeInterval(seconds), rate: 21) == 0)
        #expect(RescueAbsorption.remaining(of: six, at: anchor.addingTimeInterval(seconds + 1800), rate: 21) == 0)
    }

    /// Six grams used to be on the chart for seventy minutes. Against her own
    /// profile it is 25 — eight of onset and seventeen of decay — and the
    /// observed breakfast cleared 35 g in thirty-nine minutes, so this still
    /// errs long, deliberately.
    @Test func sixGramsNoLongerLastsAnHourAndAQuarter() {
        let minutes = RescueAbsorption.duration(ofGrams: 6, rate: 21) / 60

        #expect(abs(minutes - 25) < 0.2, "eight minutes of onset plus seventeen of decay")
        #expect(minutes > RescueAbsorption.onset / 60, "the onset ramp is still in there")
    }

    @Test func aBatchIsSummedAcrossEntriesStillAbsorbing() {
        let batch = [entry(6), TreatmentEvent(date: after(4), amount: 6), TreatmentEvent(date: after(8), amount: 6)]

        #expect(RescueAbsorption.remaining(of: batch, at: after(8), rate: 21) > 6)
    }
}
