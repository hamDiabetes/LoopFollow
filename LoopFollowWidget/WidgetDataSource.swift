// LoopFollow
// WidgetDataSource.swift

import Foundation

/// Supplies a timeline run with something current to draw.
///
/// Nightscout is the source; the App Group cache is what the widget falls back
/// to when the site cannot be reached, and what it starts from before the first
/// fetch of a run. It used to be the other way round, and that was the bug: the
/// cache is written by the app, so it stops advancing the moment iOS suspends
/// it, and a widget woken by the relay redrew the same reading it already had.
///
/// Nothing here writes back to the cache. The app writes it, and so does the
/// refresh button, which runs to completion for exactly that purpose; a third
/// writer racing a render is not worth the round trip it would save.
enum WidgetDataSource {
    /// Readings arrive five minutes apart, so a cache younger than this has
    /// nothing behind it to go and get. Set a little under the interval because
    /// the reading's own timestamp is what ages, not the moment it was stored,
    /// and a reading that lands early would otherwise be a cycle late.
    static let refreshAfter: TimeInterval = 4 * 60 + 30

    /// WidgetKit can ask for a snapshot and a timeline back to back, and each
    /// arrives with the cache in the same state, so without this they would each
    /// go and fetch the same thing. Only helps within one process — the
    /// extension is often started fresh, and damping across processes would mean
    /// writing the cache. WidgetKit's own reload budget is the real limiter.
    private static let repeatWindow: TimeInterval = 45

    private actor RecentFetch {
        static let shared = RecentFetch()

        private var at: Date?
        private var outcome: WidgetNightscoutRefresh.Outcome?

        func recent(within window: TimeInterval) -> WidgetNightscoutRefresh.Outcome? {
            guard let at, let outcome, Date().timeIntervalSince(at) < window else { return nil }
            return outcome
        }

        func store(_ outcome: WidgetNightscoutRefresh.Outcome) {
            at = Date()
            self.outcome = outcome
        }
    }

    /// The chart series, the reading and the forecast, as current as this run
    /// could make them.
    ///
    /// A fetch that fails or brings nothing newer leaves all three exactly as
    /// they were cached. Half a fetch is never drawn over a whole cache: the
    /// three are replaced together or not at all, because the widget states one
    /// age over the reading and the metrics beside it, and a mixture would put
    /// that age over values from a different moment.
    static func load() async -> (series: GlucoseChartSeries?, snapshot: GlucoseSnapshot?, prediction: GlucosePrediction?) {
        let cachedSeries = GlucoseChartSeriesStore.shared.load()
        let cachedSnapshot = GlucoseSnapshotStore.shared.load()
        let cachedPrediction = GlucosePredictionStore.shared.load()
        let cached = (cachedSeries, cachedSnapshot, cachedPrediction)

        guard shouldFetch(snapshot: cachedSnapshot, series: cachedSeries) else { return cached }

        let stored = cachedSnapshot?.updatedAt ?? .distantPast
        let outcome: WidgetNightscoutRefresh.Outcome
        if let recent = await RecentFetch.shared.recent(within: repeatWindow) {
            outcome = recent
        } else {
            outcome = await WidgetNightscoutRefresh.fetch(newerThan: stored)
            await RecentFetch.shared.store(outcome)
        }

        guard case let .refreshed(payload) = outcome else { return cached }
        return (payload.series, payload.snapshot, payload.prediction)
    }

    /// Nothing to go and get while the app is awake and writing: it sources
    /// fields this path cannot, so its cache is the better copy right up until
    /// it stops being current.
    private static func shouldFetch(snapshot: GlucoseSnapshot?, series: GlucoseChartSeries?) -> Bool {
        guard let snapshot, series != nil else { return true }
        return Date().timeIntervalSince(snapshot.updatedAt) >= refreshAfter
    }
}
