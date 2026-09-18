// LoopFollow
// WidgetReadingCache.swift

import Foundation

/// The reading half of a widget refresh: what the App Group already holds,
/// whether it is worth going out for something newer, and putting back what came
/// of it.
///
/// The last of those is why this is a type rather than four lines inside the
/// timeline. A run that fetches and does not write the reading back leaves the
/// next run looking at the same stale cache and going out again, so the age
/// check can never say no on the one surface it exists for: the widget runs
/// while the app is suspended, and a suspended app is not advancing the cache
/// for it.
///
/// The stores are passed in so the sequence can be run against a cache held in
/// memory. `WidgetDataSource` hands it the App Group ones; a test hands it a
/// dictionary and counts fetches.
struct WidgetReadingCache {
    /// The three files that move together. They are replaced as a set because
    /// the widget states one age over the reading and the metrics beside it, and
    /// a mixture would put that age over values from a different moment.
    struct Reading {
        let series: GlucoseChartSeries
        let snapshot: GlucoseSnapshot
        /// Nil where the cycle carried no forecast, which is a forecast to clear
        /// rather than one to leave standing.
        let prediction: GlucosePrediction?

        init(series: GlucoseChartSeries, snapshot: GlucoseSnapshot, prediction: GlucosePrediction?) {
            self.series = series
            self.snapshot = snapshot
            self.prediction = prediction
        }
    }

    typealias Cached = (series: GlucoseChartSeries?, snapshot: GlucoseSnapshot?, prediction: GlucosePrediction?)

    /// Readings arrive five minutes apart, so a cache younger than this has
    /// nothing behind it to go and get. Set a little under the interval because
    /// the reading's own timestamp is what ages, not the moment it was stored,
    /// and a reading that lands early would otherwise be a cycle late.
    static let refreshAfter: TimeInterval = 4 * 60 + 30

    let load: () -> Cached
    let save: (Reading) async -> Void

    /// The cached reading, or a fetched one that has been written back.
    ///
    /// `fetch` is given the stored timestamp so it can decline to answer with
    /// anything older, and returns nil when it could not or had nothing newer —
    /// in which case the cache stands untouched, since half a fetch drawn over a
    /// whole cache is worse than the cache.
    func readings(now: Date = Date(), fetch: (Date) async -> Reading?) async -> Cached {
        let cached = load()
        guard Self.shouldFetch(snapshot: cached.snapshot, series: cached.series, now: now) else { return cached }

        guard let fetched = await fetch(cached.snapshot?.updatedAt ?? .distantPast) else { return cached }

        // Awaited, not fired off: the caller redraws the moment this returns,
        // and the next run's age check reads what this writes.
        await save(fetched)
        return (fetched.series, fetched.snapshot, fetched.prediction)
    }

    /// Nothing to go and get while the app is awake and writing: it sources
    /// fields the widget's own fetch cannot, so its cache is the better copy
    /// right up until it stops being current.
    static func shouldFetch(snapshot: GlucoseSnapshot?, series: GlucoseChartSeries?, now: Date = Date()) -> Bool {
        guard let snapshot, series != nil else { return true }
        return now.timeIntervalSince(snapshot.updatedAt) >= refreshAfter
    }
}
