// LoopFollow
// WidgetDataSource.swift

import Foundation

/// Reads what the app cached in the App Group and, when that has gone stale,
/// tops it up from Nightscout. Nothing here writes back to the cache.
enum WidgetDataSource {
    /// Three missed five-minute readings.
    static let staleAfter: TimeInterval = 15 * 60

    /// The forecast comes back as it was stored, never renewed here: this path
    /// tops up from entries alone, which carry no forecast, so a fetch on it
    /// leaves the stored one exactly as old as it was. The chart places it
    /// against its own anchor, so an old forecast sits behind the now line
    /// rather than claiming the space in front of it.
    static func load() async -> (series: GlucoseChartSeries?, snapshot: GlucoseSnapshot?, prediction: GlucosePrediction?) {
        let cached = GlucoseChartSeriesStore.shared.load()
        let snapshot = GlucoseSnapshotStore.shared.load()
        let prediction = GlucosePredictionStore.shared.load()

        if let cached = cached, cached.age <= staleAfter {
            return (cached, snapshot, prediction)
        }

        let url = LAAppGroupSettings.nightscoutURL()
        guard !url.isEmpty else { return (cached, snapshot, prediction) }

        // Entries cannot supply the snapshot's secondary metrics.
        guard let fetched = await NightscoutChartFetcher.fetchSeries(baseURL: url, token: LAAppGroupSettings.nightscoutToken()),
              (fetched.points.last?.date ?? .distantPast) >= (cached?.points.last?.date ?? .distantPast)
        else {
            return (cached, snapshot, prediction)
        }
        return (fetched, snapshot, prediction)
    }
}
