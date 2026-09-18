// LoopFollow
// FetchCoverageTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What a capped query is entitled to claim.
///
/// The failure is quiet: a query cut off at its cap looks exactly like a query
/// that found everything, and the chart downstream draws the difference as
/// "nothing happened" over hours nobody read.
struct FetchCoverageTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date {
        anchor.addingTimeInterval(minutes * 60)
    }

    @Test func aShortAnswerCoversTheWholeWindow() {
        let dates = [at(0), at(30), at(60)]

        #expect(FetchCoverage.bound(records: 3, dates: dates, asked: 400) == nil)
    }

    @Test func nothingFoundIsStillAnAnswer() {
        #expect(FetchCoverage.bound(records: 0, dates: [], asked: 400) == nil)
    }

    /// Truncation is a fact about records and the bound is a fact about dates.
    /// A record that could not be dated still proves the query read that far, so
    /// counting dates instead of records would report a truncated answer as a
    /// complete one — and that is the direction that looks safe.
    @Test func anUndatedRecordDoesNotMakeAFullAnswerLookShort() {
        let dated = [at(120), at(90)]

        #expect(FetchCoverage.bound(records: 3, dates: dated, asked: 3) == at(90))
    }

    /// A full answer none of whose records could be dated establishes nothing
    /// placeable, which is a chart with no history rather than one with no
    /// treatments.
    @Test func aFullAnswerOfUndatedRecordsCoversNothing() {
        let now = at(500)

        #expect(FetchCoverage.bound(records: 3, dates: [], asked: 3, now: now) == now)
    }

    /// The case that matters: as many records as were asked for, so the oldest
    /// one is as far back as the query can speak for.
    @Test func afullAnswerCoversOnlyBackToItsOldestRecord() {
        let dates = [at(120), at(60), at(90)]

        #expect(FetchCoverage.bound(records: 3, dates: dates, asked: 3) == at(60))
    }

    /// Nightscout answers newest first, so the oldest record is the last one
    /// back — the bound is the minimum rather than whatever arrived last.
    @Test func theBoundIsTheOldestRecordWhateverOrderTheyArriveIn() {
        let ascending = [at(10), at(20), at(30)]

        #expect(FetchCoverage.bound(records: 3, dates: ascending, asked: 3) == at(10))
        #expect(FetchCoverage.bound(records: 3, dates: ascending.reversed(), asked: 3) == at(10))
    }

    /// Two queries, and only the truncated one limits what is known. The other
    /// covering the whole window says nothing about the hours the first could
    /// not reach.
    @Test func theJointBoundIsTheLatestOfThem() {
        #expect(FetchCoverage.bound(of: [nil, at(60)]) == at(60))
        #expect(FetchCoverage.bound(of: [at(30), at(60)]) == at(60))
        #expect(FetchCoverage.bound(of: [nil, nil]) == nil)
        #expect(FetchCoverage.bound(of: []) == nil)
    }

    /// And what the chart does with it, which is the point of recording it: the
    /// bound is `coveredFrom`, and everything older reads as unobserved rather
    /// than as a stretch in which no insulin was given.
    @Test func whatIsOlderThanTheBoundIsNotClaimed() {
        let bound = at(60)
        let ribbons = TreatmentRibbons(
            insulin: [TreatmentEvent(date: at(90), amount: 1.2)],
            carbsOnBoard: nil,
            rescue: [],
            coveredFrom: bound
        )

        #expect(ribbons.coveredFrom == bound)
        // The renderer gates on `coveredFrom`; this is the fact it gates with.
        #expect(ribbons.insulin?.allSatisfy { $0.date >= bound } == true)
    }
}
