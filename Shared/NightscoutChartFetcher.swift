// LoopFollow
// NightscoutChartFetcher.swift

import Foundation

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

    /// The last `GlucoseChartSeriesStore.window` of readings, oldest first, or nil.
    static func fetchSeries(baseURL: String, token: String) async -> GlucoseChartSeries? {
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
            return try series(from: JSONDecoder().decode([Entry].self, from: data))
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
