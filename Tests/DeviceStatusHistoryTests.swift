// LoopFollow
// DeviceStatusHistoryTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The window of devicestatus the poll now asks for, and what is read out of it.
///
/// The chart's ribbons drew as scattered blocks because the poll asked for one
/// record: the series held only the cycles the app happened to be running for.
/// These cover the two halves of the fix — where the window starts, and what a
/// window of records yields.
struct DeviceStatusHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 24 * 3600

    private func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]
        return formatter
    }

    private func stamp(_ date: Date) -> String {
        formatter().string(from: date)
    }

    private func openAPSRecord(cycle: Date?, iob: Double?, cob: Double?, reason: String? = nil, failed: Bool = false) -> [String: AnyObject] {
        var suggested: [String: AnyObject] = [:]
        if let cycle { suggested["deliverAt"] = stamp(cycle) as AnyObject }
        if let cob { suggested["COB"] = cob as AnyObject }
        if let reason { suggested["reason"] = reason as AnyObject }

        var openAPS: [String: AnyObject] = ["suggested": suggested as AnyObject]
        if let iob { openAPS["iob"] = ["iob": iob] as AnyObject }
        if failed { openAPS["failureReason"] = "pump comms" as AnyObject }
        return ["openaps": openAPS as AnyObject]
    }

    // MARK: - Where the window starts

    @Test func anEmptyStoreReachesBackAWholeWindow() {
        let since = MainViewController.deviceStatusSince(newestHeld: nil, now: now, window: window)
        #expect(since == now.addingTimeInterval(-window))
    }

    @Test func aHeldSeriesIsContinuedRatherThanRefetched() {
        let held = now.addingTimeInterval(-90 * 60)
        let since = MainViewController.deviceStatusSince(newestHeld: held, now: now, window: window)
        #expect(since == held.addingTimeInterval(1))
    }

    /// The case that would otherwise put an unbounded download on the poll: a
    /// store last written days ago, or a clock that moved.
    @Test func aHeldSeriesOlderThanTheWindowDoesNotReachBackFurtherThanTheWindow() {
        let stale = now.addingTimeInterval(-40 * 3600)
        let since = MainViewController.deviceStatusSince(newestHeld: stale, now: now, window: window)
        #expect(since == now.addingTimeInterval(-window))
    }

    /// The upgrade case, and the one that decides whether anybody sees the fix.
    ///
    /// A phone arriving at this build holds the sparse series the old poll
    /// built, and its newest sample is as recent as the last time the app was
    /// open. Bounding the fetch on that would skip every old hole.
    @Test func aRecentSampleInASparseStoreMustNotBoundTheFirstFetch() {
        let sparseButRecent = now.addingTimeInterval(-120)

        let resume = MainViewController.resumePoint(
            backfilled: false,
            carbs: sparseButRecent,
            insulin: sparseButRecent
        )

        #expect(resume == nil)
    }

    @Test func aBackfilledStoreIsResumedFromWhatItHolds() {
        let held = now.addingTimeInterval(-300)
        #expect(MainViewController.resumePoint(backfilled: true, carbs: held, insulin: held) == held)
    }

    /// The two series are written separately and one can lose a race. Resuming
    /// from the newer would leave the other short by exactly the cycles it
    /// missed.
    @Test func theOlderOfTheTwoSeriesDecidesWhereAPollResumes() {
        let carbs = now.addingTimeInterval(-300)
        let insulin = now.addingTimeInterval(-900)
        #expect(MainViewController.resumePoint(backfilled: true, carbs: carbs, insulin: insulin) == insulin)
    }

    @Test func oneEmptySeriesSendsThePollBackToTheWholeWindow() {
        #expect(MainViewController.resumePoint(backfilled: true, carbs: now, insulin: nil) == nil)
    }

    // MARK: - What a window yields

    @Test func everyRecordInTheWindowBecomesASample() {
        let records = (0 ..< 5).map { index in
            openAPSRecord(cycle: now.addingTimeInterval(Double(-index) * 300), iob: 1.5, cob: 20)
        }

        let onBoard = DeviceStatusHistory.onBoard(from: records, formatter: formatter())

        #expect(onBoard.carbs.count == 5)
        #expect(onBoard.insulin.count == 5)
    }

    /// Nightscout answers newest first and the stores hold oldest first. A
    /// series handed over in arrival order reports one observed stretch per
    /// sample, which is the scattered-blocks defect by another route.
    @Test func samplesComeBackOldestFirstWhateverOrderTheyArrivedIn() {
        let records = (0 ..< 4).map { index in
            openAPSRecord(cycle: now.addingTimeInterval(Double(-index) * 300), iob: 1, cob: 5)
        }

        let onBoard = DeviceStatusHistory.onBoard(from: records, formatter: formatter())

        #expect(onBoard.carbs.map(\.date) == onBoard.carbs.map(\.date).sorted())
        #expect(onBoard.carbs.first?.date == now.addingTimeInterval(-900))
        #expect(onBoard.carbs.last?.date == now)
    }

    @Test func aFailedCycleIsNotASample() {
        let records = [
            openAPSRecord(cycle: now, iob: 1, cob: 10),
            openAPSRecord(cycle: now.addingTimeInterval(-300), iob: 1, cob: 10, failed: true),
        ]

        let onBoard = DeviceStatusHistory.onBoard(from: records, formatter: formatter())

        #expect(onBoard.insulin.count == 1)
        #expect(onBoard.insulin.first?.date == now)
    }

    /// A record with figures but nowhere to put them. Dropping it leaves a gap,
    /// which is the honest answer; placing it at the fetch would draw insulin at
    /// a time nobody reported it.
    @Test func aCycleWithNoTimestampIsDropped() {
        let onBoard = DeviceStatusHistory.onBoard(
            from: [openAPSRecord(cycle: nil, iob: 2, cob: 30)],
            formatter: formatter()
        )

        #expect(onBoard.isEmpty)
    }

    /// Some uploaders state carbs on board only in the human-readable line. The
    /// header already falls back to it, and a ribbon that did not would draw a
    /// hole on a site whose header shows a figure.
    @Test func carbsAreReadFromTheReasonLineWhenTheFieldIsAbsent() {
        let onBoard = DeviceStatusHistory.onBoard(
            from: [openAPSRecord(cycle: now, iob: 1, cob: nil, reason: "COB: 42, Dev: 3, BGI: 1")],
            formatter: formatter()
        )

        #expect(onBoard.carbs.first?.grams == 42)
    }

    @Test func aRecordWithNoCarbFigureAtAllYieldsNoCarbSample() {
        let onBoard = DeviceStatusHistory.onBoard(
            from: [openAPSRecord(cycle: now, iob: 1, cob: nil, reason: "Dev: 3, BGI: 1")],
            formatter: formatter()
        )

        #expect(onBoard.carbs.isEmpty)
        #expect(onBoard.insulin.count == 1)
    }

    // MARK: - Folding a window into a store

    @Test func aWindowMergesOnlyWhatIsNotAlreadyHeld() throws {
        let stored = [
            CarbsOnBoardSample(date: now.addingTimeInterval(-600), grams: 10),
            CarbsOnBoardSample(date: now.addingTimeInterval(-300), grams: 12),
        ]
        let incoming = [
            CarbsOnBoardSample(date: now.addingTimeInterval(-300), grams: 12),
            CarbsOnBoardSample(date: now, grams: 14),
        ]

        let merged = try #require(OnBoardMerge.merging(stored, with: incoming))

        #expect(merged.count == 3)
        #expect(merged.map(\.date) == merged.map(\.date).sorted())
    }

    @Test func aWindowThatRestatesTheStoreIsNotAWrite() {
        let stored = [CarbsOnBoardSample(date: now, grams: 10)]
        #expect(OnBoardMerge.merging(stored, with: stored) == nil)
    }

    /// A cycle republished under a second record. Two samples on one instant is
    /// a zero-length spacing, which the observed grid reads as a stretch of no
    /// width.
    @Test func aCycleRepeatedWithinOneWindowIsTakenOnce() throws {
        let repeated = [
            InsulinOnBoardSample(date: now, units: 1.2),
            InsulinOnBoardSample(date: now, units: 1.2),
        ]

        let merged = try #require(OnBoardMerge.merging([InsulinOnBoardSample](), with: repeated))

        #expect(merged.count == 1)
    }

    /// The reason a windowed fetch fixes the ribbon at all: a day of cycles at
    /// the real cadence is one observed stretch, where the same day seen only
    /// while the app was open is a stretch per visit.
    @Test func aWindowOfCyclesAtTheRealCadenceIsOneStretch() throws {
        let samples = (0 ..< 288).map {
            CarbsOnBoardSample(date: now.addingTimeInterval(Double(-$0) * 240), grams: 20)
        }.sorted { $0.date < $1.date }

        let grid = try #require(CarbsOnBoardHistory(samples: samples, updatedAt: now).grid())

        #expect(grid.stretches.count == 1)
    }
}
