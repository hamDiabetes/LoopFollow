// LoopFollow
// GlucoseChartSeries.swift

import Foundation

/// A single glucose reading plotted on the home screen widget chart.
struct GlucoseChartPoint: Codable, Equatable, Hashable {
    /// Glucose value in mg/dL (canonical internal unit).
    let value: Double

    /// Timestamp of the reading.
    let date: Date

    init(value: Double, date: Date) {
        self.value = value
        self.date = date
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(date.timeIntervalSince1970, forKey: .date)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Double.self, forKey: .value)
        date = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .date))
    }

    private enum CodingKeys: String, CodingKey {
        case value, date
    }
}

/// Recent glucose history for the home screen widget chart.
///
/// Thresholds and the preferred display unit are read separately from
/// `LAAppGroupSettings`, so this stays a plain series of readings.
struct GlucoseChartSeries: Codable, Equatable {
    /// Readings ordered oldest first.
    let points: [GlucoseChartPoint]

    /// When the app last wrote this series.
    let updatedAt: Date

    /// Age of the series in seconds.
    var age: TimeInterval {
        Date().timeIntervalSince(updatedAt)
    }

    init(points: [GlucoseChartPoint], updatedAt: Date) {
        self.points = points
        self.updatedAt = updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([GlucoseChartPoint].self, forKey: .points)
        updatedAt = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .updatedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case points, updatedAt
    }
}

/// Persists the recent glucose history into the App Group container so the
/// home screen widget can render a chart without the app running.
///
/// Uses an atomic JSON file write to avoid partial/corrupt reads across processes.
final class GlucoseChartSeriesStore {
    static let shared = GlucoseChartSeriesStore()
    private init() {}

    /// Readings older than this are dropped when saving. Covers the longest
    /// `WidgetChartDuration`, since the widget can only draw what is stored.
    static let window: TimeInterval = 24 * 3600

    private let fileName = "glucose_chart_series.json"
    private let queue = DispatchQueue(label: "com.loopfollow.glucoseChartSeriesStore", qos: .utility)

    // MARK: - Public API

    /// The write is asynchronous, so callers that have to act on the stored file
    /// (asking the widget to redraw, for one) pass `completion` rather than
    /// assuming the series has landed when `save` returns.
    func save(_ series: GlucoseChartSeries, completion: (() -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            do {
                let url = try self.fileURL()
                let data = try JSONEncoder().encode(series)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Intentionally silent (extension-safe, no dependencies).
            }
        }
    }

    func load() -> GlucoseChartSeries? {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GlucoseChartSeries.self, from: data)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    // MARK: - Helpers

    private func fileURL() throws -> URL {
        let groupID = AppGroupID.current()
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(
                domain: "GlucoseChartSeriesStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group containerURL is nil for id=\(groupID)"],
            )
        }
        return containerURL.appendingPathComponent(fileName, isDirectory: false)
    }
}
