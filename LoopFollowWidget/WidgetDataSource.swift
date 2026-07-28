// LoopFollow
// WidgetDataSource.swift

import Foundation

/// Reads what the app cached in the App Group and, when that has gone stale,
/// tops it up from Nightscout. Nothing here writes back to the cache.
enum WidgetDataSource {
    /// Three missed five-minute readings.
    static let staleAfter: TimeInterval = 15 * 60

    static func load() async -> (series: GlucoseChartSeries?, snapshot: GlucoseSnapshot?) {
        let cached = GlucoseChartSeriesStore.shared.load()
        let snapshot = GlucoseSnapshotStore.shared.load()

        if let cached = cached, cached.age <= staleAfter {
            return (cached, snapshot)
        }

        let url = LAAppGroupSettings.nightscoutURL()
        guard !url.isEmpty else { return (cached, snapshot) }

        // Entries cannot supply the snapshot's secondary metrics.
        guard let fetched = await NightscoutChartFetcher.fetchSeries(baseURL: url, token: LAAppGroupSettings.nightscoutToken()),
              (fetched.points.last?.date ?? .distantPast) >= (cached?.points.last?.date ?? .distantPast)
        else {
            return (cached, snapshot)
        }
        return (fetched, snapshot)
    }
}
