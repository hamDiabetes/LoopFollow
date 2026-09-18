// LoopFollow
// WidgetReadingCacheTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// What a widget run owes the run after it.
///
/// The widget exists because the app is suspended, so the App Group cache it
/// checks its own age against is advanced by nobody but itself. A run that
/// fetched and did not write back left the next run reading the same stale
/// reading and going out for it again — fifteen requests a reload against a
/// budget that allows hundreds a day. These drive the sequence against a cache
/// held in memory and count the fetches, because the number of fetches is the
/// thing that was wrong; that a save function got called is not.
struct WidgetReadingCacheTests {
    private let anchor = Date(timeIntervalSince1970: 1_757_000_000)

    /// Stands in for the three App Group files. Loads see whatever the last save
    /// wrote, which is the only property of the real stores this sequence
    /// depends on.
    private final class Cache {
        var series: GlucoseChartSeries?
        var snapshot: GlucoseSnapshot?
        var prediction: GlucosePrediction?

        var reader: WidgetReadingCache {
            WidgetReadingCache(
                load: { (self.series, self.snapshot, self.prediction) },
                save: { reading in
                    self.prediction = reading.prediction
                    self.series = reading.series
                    self.snapshot = reading.snapshot
                }
            )
        }
    }

    private func reading(at date: Date, glucose: Double = 120, prediction: GlucosePrediction? = nil) -> WidgetReadingCache.Reading {
        WidgetReadingCache.Reading(
            series: GlucoseChartSeries(
                points: [GlucoseChartPoint(value: glucose, date: date)],
                updatedAt: date
            ),
            snapshot: GlucoseSnapshot(
                glucose: glucose,
                delta: 0,
                trend: .flat,
                updatedAt: date,
                iob: nil,
                cob: nil,
                projected: nil,
                unit: .mgdl,
                isNotLooping: false
            ),
            prediction: prediction
        )
    }

    /// The bug, stated as the behaviour it breaks. Two runs a minute apart, and
    /// the second is inside the window the first one's reading opened, so it has
    /// nothing to go and get. Without the write-back the second run finds the
    /// cache exactly as the first one found it and pays for the fetch again —
    /// and so does every run after that, for as long as the app stays asleep.
    @Test func aSecondRunInsideTheWindowDoesNotFetchAgain() async {
        let cache = Cache()
        var fetches = 0

        _ = await cache.reader.readings(now: anchor) { _ in
            fetches += 1
            return self.reading(at: self.anchor)
        }
        _ = await cache.reader.readings(now: anchor.addingTimeInterval(60)) { _ in
            fetches += 1
            return self.reading(at: self.anchor)
        }

        #expect(fetches == 1)
    }

    /// And the run after the window is up goes out again, so the write-back
    /// damps the path rather than stopping it. A cache that silenced every later
    /// run would pass the test above and freeze the widget.
    @Test func aRunPastTheWindowFetchesAgain() async {
        let cache = Cache()
        var fetches = 0

        _ = await cache.reader.readings(now: anchor) { _ in
            fetches += 1
            return self.reading(at: self.anchor)
        }
        let later = anchor.addingTimeInterval(WidgetReadingCache.refreshAfter + 1)
        _ = await cache.reader.readings(now: later) { _ in
            fetches += 1
            return self.reading(at: later, glucose: 140)
        }

        #expect(fetches == 2)
    }

    /// An empty cache is a widget that knows nothing, not a fresh one.
    @Test func nothingCachedIsWorthFetching() async {
        let cache = Cache()
        var fetches = 0

        let result = await cache.reader.readings(now: anchor) { _ in
            fetches += 1
            return self.reading(at: self.anchor, glucose: 96)
        }

        #expect(fetches == 1)
        #expect(result.snapshot?.glucose == 96)
        #expect(result.series?.points.count == 1)
    }

    /// A reading without a series behind it cannot draw a chart, so its age is
    /// not the question. This is the state an install is in after the reading
    /// file is written and before the first series lands.
    @Test func aFreshReadingWithNoSeriesIsStillWorthFetching() async {
        let cache = Cache()
        cache.snapshot = reading(at: anchor).snapshot
        var fetches = 0

        _ = await cache.reader.readings(now: anchor) { _ in
            fetches += 1
            return self.reading(at: self.anchor)
        }

        #expect(fetches == 1)
    }

    /// A fetch that came back with nothing leaves all three as they were. The
    /// widget then draws the cache under its own age, which is the honest thing
    /// to draw, rather than a hole where the site should have answered.
    @Test func aFetchThatBroughtNothingLeavesTheCacheStanding() async {
        let cache = Cache()
        let stored = reading(at: anchor, glucose: 88)
        cache.series = stored.series
        cache.snapshot = stored.snapshot

        let stale = anchor.addingTimeInterval(WidgetReadingCache.refreshAfter + 1)
        let result = await cache.reader.readings(now: stale) { _ in nil }

        #expect(result.snapshot?.glucose == 88)
        #expect(cache.snapshot?.glucose == 88)
    }

    /// The fetch is told how old the stored reading is, since that is what it
    /// declines to answer with anything older than. An empty cache asks for
    /// anything at all.
    @Test func theFetchIsToldWhatIsAlreadyStored() async {
        let cache = Cache()
        var asked: [Date] = []

        _ = await cache.reader.readings(now: anchor) { stored in
            asked.append(stored)
            return self.reading(at: self.anchor)
        }
        let later = anchor.addingTimeInterval(WidgetReadingCache.refreshAfter + 1)
        _ = await cache.reader.readings(now: later) { stored in
            asked.append(stored)
            return self.reading(at: later)
        }

        #expect(asked == [.distantPast, anchor])
    }

    /// The forecast moves with the reading, including when the cycle carried
    /// none: a forecast left behind would be drawn against a reading it was not
    /// computed from.
    @Test func aCycleWithNoForecastClearsTheStoredOne() async {
        let cache = Cache()
        let forecast = GlucosePrediction(
            curves: ["IOB": [120, 118, 115]],
            source: .openAPS,
            anchor: anchor,
            updatedAt: anchor
        )

        _ = await cache.reader.readings(now: anchor) { _ in
            self.reading(at: self.anchor, prediction: forecast)
        }
        #expect(cache.prediction?.curves["IOB"] == [120, 118, 115])

        let later = anchor.addingTimeInterval(WidgetReadingCache.refreshAfter + 1)
        _ = await cache.reader.readings(now: later) { _ in
            self.reading(at: later)
        }
        #expect(cache.prediction == nil)
    }
}
