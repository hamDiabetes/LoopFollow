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

/// Which app's loop published a forecast, so the widget draws the right shape
/// without a second setting asking which one is in use.
enum GlucosePredictionSource: String, Codable {
    case openAPS
    case loop
}

/// The spread across the published curves at one moment of the forecast.
/// `low == high` wherever a single curve is all there is to spread.
struct GlucosePredictionBand: Equatable, Hashable {
    let date: Date
    let low: Double
    let high: Double
}

/// The forecast the loop last published, kept as the separate curves it was
/// published as rather than as a precomputed envelope, so the widget can decide
/// how far forward to draw without the app having to guess first.
///
/// Values are mg/dL, clamped to the display range by whoever writes the file.
/// Samples are `step` apart beginning at `anchor`.
struct GlucosePrediction: Codable, Equatable {
    /// Keyed "ZT"/"IOB"/"COB"/"UAM" for openAPS, a single "values" for Loop.
    /// oref publishes only the curves that apply, so this is often two of the
    /// four and occasionally one.
    let curves: [String: [Double]]

    let source: GlucosePredictionSource

    /// The loop cycle the forecast runs forward from, which is not when this
    /// file was written. Everything the widget draws is placed against this.
    let anchor: Date

    /// When the app or the widget's own refresh last wrote this.
    let updatedAt: Date

    /// The app clamps with `globalVariables`, which is not reachable from an
    /// extension, so both writers share these instead of drifting apart.
    static let minMgdl: Double = 39
    static let maxMgdl: Double = 400

    /// Spacing oref and Loop both publish their forecasts at.
    static let step: TimeInterval = 300

    /// Longest forecast worth storing. The widget never offers more than an
    /// hour, and this leaves room to raise that without a stored format change.
    static let maxSamples = 37

    /// A forecast with nothing to disagree about has no width to draw, so it is
    /// a line rather than a cone. Loop always lands here; oref does whenever it
    /// publishes one curve.
    var isSingleCurve: Bool {
        curves.values.filter { !$0.isEmpty }.count < 2
    }

    /// The envelope, from the anchor up to `end`, as the per-index spread across
    /// every curve present.
    ///
    /// Truncated at the shortest curve. The curves are published at different
    /// lengths and which one is shortest varies between cycles, so carrying on
    /// past it would narrow the band wherever a contributor ran out. A band that
    /// narrows reads as the model growing certain, when all that happened is
    /// that one of its inputs stopped. Nothing here extrapolates: the forecast
    /// ends where the published data ends.
    func bands(upTo end: Date) -> [GlucosePredictionBand] {
        let arrays = curves.values.filter { !$0.isEmpty }
        guard let shortest = arrays.map(\.count).min() else { return [] }

        let span = end.timeIntervalSince(anchor)
        guard span >= 0 else { return [] }
        let limit = min(shortest, Int(span / Self.step) + 1, Self.maxSamples)
        guard limit > 1 else { return [] }

        return (0 ..< limit).map { index in
            let values = arrays.map { $0[index] }
            return GlucosePredictionBand(
                date: anchor.addingTimeInterval(Self.step * Double(index)),
                low: values.min() ?? 0,
                high: values.max() ?? 0
            )
        }
    }

    init(curves: [String: [Double]], source: GlucosePredictionSource, anchor: Date, updatedAt: Date) {
        self.curves = curves
        self.source = source
        self.anchor = anchor
        self.updatedAt = updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(curves, forKey: .curves)
        try container.encode(source, forKey: .source)
        try container.encode(anchor.timeIntervalSince1970, forKey: .anchor)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        curves = try container.decode([String: [Double]].self, forKey: .curves)
        source = try container.decode(GlucosePredictionSource.self, forKey: .source)
        anchor = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .anchor))
        updatedAt = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .updatedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case curves, source, anchor, updatedAt
    }
}

/// Persists the last published forecast into the App Group container.
///
/// Kept out of `GlucoseSnapshot`, which is compared whole to decide whether the
/// widget needs redrawing and is compiled into the Live Activity as well: a
/// forecast in there would make every loop cycle look like a change, and the
/// Live Activity has no use for one. Readings and forecasts also arrive on
/// different fetches, so separate files keep each one's age honest.
final class GlucosePredictionStore {
    static let shared = GlucosePredictionStore()
    private init() {}

    private let fileName = "glucose_prediction.json"
    private let queue = DispatchQueue(label: "com.loopfollow.glucosePredictionStore", qos: .utility)

    /// Asynchronous for the same reason as the series store, so callers that
    /// have to act on the written file wait for `completion`.
    func save(_ prediction: GlucosePrediction, completion: (() -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            do {
                let url = try self.fileURL()
                let data = try JSONEncoder().encode(prediction)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Intentionally silent (extension-safe, no dependencies).
            }
        }
    }

    /// Removes the stored forecast. A loop that stopped publishing one has to
    /// take the old one off the widget with it, rather than leave it standing.
    func clear(completion: (() -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard let url = try? self.fileURL() else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func load() -> GlucosePrediction? {
        do {
            let url = try fileURL()
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GlucosePrediction.self, from: data)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    private func fileURL() throws -> URL {
        let groupID = AppGroupID.current()
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(
                domain: "GlucosePredictionStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group containerURL is nil for id=\(groupID)"],
            )
        }
        return containerURL.appendingPathComponent(fileName, isDirectory: false)
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
