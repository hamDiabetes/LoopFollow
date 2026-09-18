// LoopFollow
// TreatmentDateTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// Every SMB and Bolus this family's Nightscout holds carries `created_at` and
/// nothing else — no `date`, no `mills`, across 1917 records in 30 days. So the
/// whole insulin ribbon, the largest series on the chart, is parsed by the
/// fallback branch.
struct TreatmentDateTests {
    private func epoch(_ record: [String: Any]) -> Double? {
        NightscoutDate.eventDate(record)?.timeIntervalSince1970
    }

    /// The form Nightscout actually writes: fractional seconds, Z.
    @Test func aRealBolusRecordParses() {
        #expect(epoch(["created_at": "2026-09-06T04:49:46.626Z", "insulin": 1.7]) == 1_788_670_186.626)
    }

    @Test func fractionalSecondsAreOptional() {
        #expect(epoch(["created_at": "2026-09-06T04:49:46Z"]) == 1_788_670_186)
    }

    @Test func anOffsetIsHonouredRatherThanIgnored() {
        #expect(epoch(["created_at": "2026-09-06T04:49:46-05:00"]) == 1_788_688_186)
        #expect(epoch(["created_at": "2026-09-06T04:49:46+0200"]) == 1_788_662_986)
    }

    /// `as? NSNumber` rejecting NSNull is what makes the fallback fire at all,
    /// and a key present and null is what Nightscout writes.
    @Test func anExplicitNullDateFallsThroughToCreatedAt() {
        #expect(epoch(["date": NSNull(), "created_at": "2026-09-06T04:49:46.626Z"]) == 1_788_670_186.626)
        #expect(epoch(["date": 0, "created_at": "2026-09-06T04:49:46.626Z"]) == 1_788_670_186.626)
    }

    @Test func millisecondsWinWhenThereAreAny() {
        #expect(epoch(["date": 1_788_000_000_000, "created_at": "2026-09-06T04:49:46.626Z"]) == 1_788_000_000)
    }

    /// What has to stay nil, so a bad string cannot become a plausible instant.
    @Test func whatCannotBeParsedIsNotGuessed() {
        #expect(epoch(["created_at": ""]) == nil)
        #expect(epoch(["created_at": "not a date"]) == nil)
        #expect(epoch(["created_at": "2026-09-06 04:49:46.626Z"]) == nil)
        #expect(epoch(["created_at": NSNull()]) == nil)
        #expect(epoch(["insulin": 0.5]) == nil)
    }

    /// The consequence, stated where it can be seen: an unparsed date is not a
    /// misplaced event, it is an absent one, and the chart says nothing about it.
    @Test func anUnparsedRecordVanishesFromTheSeries() {
        let good: [String: Any] = ["created_at": "2026-09-06T04:49:46.626Z", "insulin": 0.5]
        let bad: [String: Any] = ["created_at": "2026-09-06 04:52:11.004Z", "insulin": 0.5]
        let series = [good, bad].compactMap { record -> TreatmentEvent? in
            guard let amount = (record["insulin"] as? NSNumber)?.doubleValue, amount > 0,
                  let date = NightscoutDate.eventDate(record) else { return nil }
            return TreatmentEvent(date: date, amount: amount)
        }
        #expect(series.count == 1)
    }
}
