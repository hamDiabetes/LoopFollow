// LoopFollow
// NightscoutChartFetcher.swift

import Foundation

/// The newest entry of a fetch, carrying the fields a plain list of chart points
/// drops. The value is the reading as posted, not the clamped one the chart
/// plots, so a reading off the end of the scale is still stated as it stands.
struct NightscoutReading {
    let mgdl: Double
    let date: Date
    let deltaMgdl: Double
    let direction: String?
}

/// Fetches recent glucose entries directly from Nightscout for surfaces that run
/// without the app. `NightscoutUtils` is unusable here: it reads `Storage.shared`
/// and logs through `LogManager`, neither of which exists in an extension.
enum NightscoutChartFetcher {
    /// Short enough that a timeline reload can afford to wait for it.
    static let timeout: TimeInterval = 4

    /// One reading per five minutes, doubled to leave room for duplicates.
    private static let entryCount = Int(GlucoseChartSeriesStore.window / 300) * 2

    private static let maxPlausibleMgdl: Double = 600

    /// Display range the app's own graph clamps to (see #600). Sensors report
    /// out-of-range and special values, and one of them would otherwise stretch
    /// the widget chart until the real readings are unreadable.
    private static let minDisplayMgdl: Double = 39
    private static let maxDisplayMgdl: Double = 400

    // MARK: - Public API

    /// Longer than this between the last two readings and the difference is not
    /// a delta: the sensor stopped reporting in between.
    private static let maxDeltaGap: TimeInterval = 20 * 60

    /// The last `GlucoseChartSeriesStore.window` of readings, oldest first, or nil.
    static func fetchSeries(baseURL: String, token: String) async -> GlucoseChartSeries? {
        await fetch(baseURL: baseURL, token: token)?.series
    }

    /// The same readings, plus the head of them as a reading in its own right, so
    /// a caller rebuilding a whole snapshot draws the chart and the number it
    /// stands beside out of one response rather than two.
    ///
    /// Nil means the request did not land. A response that lands with nothing
    /// plottable in it is the caller's to interpret, not a failure.
    static func fetch(baseURL: String, token: String) async -> (series: GlucoseChartSeries, reading: NightscoutReading?)? {
        guard let url = entriesURL(baseURL: baseURL, token: token) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            guard let series = series(from: entries) else { return nil }
            return (series, reading(from: entries))
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    // MARK: - Helpers

    /// Calibrations and meter values come back without an `sgv`.
    private struct Entry: Decodable {
        let sgv: Double?
        let date: Double?
        let direction: String?
    }

    /// The two newest plausible readings, so the delta is measured across the
    /// pair that produced it rather than assumed. A gap wide enough to have
    /// swallowed readings leaves the delta at zero, since the difference across
    /// it is not the move the arrow describes.
    private static func reading(from entries: [Entry]) -> NightscoutReading? {
        let recent = entries.compactMap { entry -> (mgdl: Double, date: Date, direction: String?)? in
            guard let sgv = entry.sgv, sgv > 0, sgv <= maxPlausibleMgdl,
                  let milliseconds = entry.date else { return nil }
            return (sgv, Date(timeIntervalSince1970: (milliseconds / 1000).rounded()), entry.direction)
        }
        .sorted { $0.date > $1.date }

        guard let head = recent.first else { return nil }
        let previous = recent.first { $0.date < head.date }
        var delta: Double = 0
        if let previous, head.date.timeIntervalSince(previous.date) <= maxDeltaGap {
            delta = head.mgdl - previous.mgdl
        }
        return NightscoutReading(mgdl: head.mgdl, date: head.date, deltaMgdl: delta, direction: head.direction)
    }

    private static func entriesURL(baseURL: String, token: String) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.path = "/api/v1/entries.json"

        var queryItems = [URLQueryItem]()
        if !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        let since = Date().addingTimeInterval(-GlucoseChartSeriesStore.window)
        queryItems.append(URLQueryItem(name: "count", value: "\(entryCount)"))
        queryItems.append(URLQueryItem(name: "find[date][$gte]", value: "\(Int(since.timeIntervalSince1970 * 1000))"))
        queryItems.append(URLQueryItem(name: "find[type][$ne]", value: "cal"))
        components?.queryItems = queryItems

        return components?.url
    }

    private static func series(from entries: [Entry]) -> GlucoseChartSeries? {
        let cutoff = Date().addingTimeInterval(-GlucoseChartSeriesStore.window)
        let points = entries.compactMap { entry -> GlucoseChartPoint? in
            guard let sgv = entry.sgv, sgv > 0, sgv <= maxPlausibleMgdl,
                  let milliseconds = entry.date else { return nil }
            let date = Date(timeIntervalSince1970: (milliseconds / 1000).rounded())
            guard date >= cutoff else { return nil }
            let clamped = min(max(sgv, minDisplayMgdl), maxDisplayMgdl)
            return GlucoseChartPoint(value: clamped, date: date)
        }
        .sorted { $0.date < $1.date }

        // More than one uploader can post the same reading, and the chart
        // identifies its points by the whole point, so a repeated timestamp
        // would collide. Keep one per timestamp.
        var deduped: [GlucoseChartPoint] = []
        for point in points where point.date != deduped.last?.date {
            deduped.append(point)
        }

        guard !deduped.isEmpty else { return nil }
        return GlucoseChartSeries(points: deduped, updatedAt: Date())
    }
}
