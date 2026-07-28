// LoopFollow
// NightscoutDeviceStatusFetcher.swift

import Foundation

/// What one `/api/v1/devicestatus.json` record can say about the metrics beside
/// the reading.
///
/// Everything the app builds out of treatments or the profile is missing here on
/// purpose: basal, override, carbs today, the site and sensor ages and the
/// profile name have no source in this response, and the widget writes them
/// empty rather than guessing.
struct NightscoutDeviceStatus {
    var iob: Double?
    var cob: Double?
    var projected: Double?
    var recBolus: Double?
    var autosens: Double?
    var tdd: Double?
    var isfMgdlPerU: Double?
    var carbRatio: Double?
    var targetLowMgdl: Double?
    var targetHighMgdl: Double?
    var battery: Double?
    var pumpBattery: Double?
    var pumpReservoirU: Double?

    /// A pump record that carries no reservoir has one the pump does not number
    /// yet, which is how the app reads the same absence.
    var pumpReservoirAboveMax = false
    var minBgMgdl: Double?
    var maxBgMgdl: Double?

    /// The forecast curves as the loop published them, so a tap renews the cone
    /// alongside the reading it is computed against rather than leaving one
    /// standing over the other. Empty when the record carries no forecast.
    var predictionCurves: [String: [Double]] = [:]
    var predictionSource: GlucosePredictionSource = .openAPS

    /// When the loop last reported, from the pump clock the app keys on too.
    var loopClock: Date?

    /// Same fifteen minute rule the app applies to the pump clock. A record
    /// without one says nothing either way, which is what a site with no loop
    /// behind it should say.
    var isNotLooping: Bool {
        guard let loopClock else { return false }
        return Date().timeIntervalSince(loopClock) >= 15 * 60
    }
}

/// Reads the loop's own numbers straight from Nightscout, for the widget's
/// refresh button. Written the way `NightscoutChartFetcher` is and for the same
/// reason: nothing in `NightscoutUtils` or `MainViewController`, where the app's
/// parsing lives, exists inside an extension.
///
/// Both device shapes are handled. Loop posts under `loop`, OpenAPS and Trio
/// under `openaps`, and the two are told apart by which key is there.
enum NightscoutDeviceStatusFetcher {
    static let timeout: TimeInterval = 4

    /// Past this the record is no longer describing now, and the widget would be
    /// putting one fresh age over a reading and a set of metrics that do not
    /// share it. The metrics are dropped instead.
    static let recordStaleAfter: TimeInterval = 15 * 60

    // MARK: - Public API

    /// Nil means the request did not land. An empty array is not a failure: a
    /// site with no loop uploading to it answers that way every time, and the
    /// caller wants an empty set of metrics, not an error.
    static func fetch(baseURL: String, token: String) async -> NightscoutDeviceStatus? {
        guard let url = statusURL(baseURL: baseURL, token: token) else { return nil }

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
            guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let record = records.first
            else {
                return NightscoutDeviceStatus()
            }
            return parse(record)
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }

    // MARK: - Parsing

    static func parse(_ record: [String: Any]) -> NightscoutDeviceStatus {
        var status = NightscoutDeviceStatus()

        if let pump = record["pump"] as? [String: Any] {
            status.loopClock = date(from: pump["clock"])
            status.pumpReservoirU = double(pump["reservoir"])
            status.pumpReservoirAboveMax = pump["reservoir"] == nil
            if let battery = pump["battery"] as? [String: Any] {
                status.pumpBattery = double(battery["percent"])
            }
        }
        if let uploader = record["uploader"] as? [String: Any] {
            status.battery = double(uploader["battery"])
        }

        if let loop = record["loop"] as? [String: Any] {
            apply(loop: loop, to: &status)
        }
        if let openaps = record["openaps"] as? [String: Any] {
            apply(openaps: openaps, to: &status)
        }

        // A record from a while back describes a moment the widget is not about
        // to claim, so keep only what stays true across the gap.
        if let clock = status.loopClock, Date().timeIntervalSince(clock) > recordStaleAfter {
            let loopClock = status.loopClock
            status = NightscoutDeviceStatus()
            status.loopClock = loopClock
        }
        return status
    }

    /// Loop keeps its numbers under nested objects and predicts a curve rather
    /// than a single value, so the projection is the end of that curve.
    private static func apply(loop: [String: Any], to status: inout NightscoutDeviceStatus) {
        // A failed loop reported nothing to read, and the app skips the record
        // wholesale in that case.
        guard loop["failureReason"] == nil else { return }

        if let iob = loop["iob"] as? [String: Any] {
            status.iob = double(iob["iob"])
        }
        if let cob = loop["cob"] as? [String: Any] {
            status.cob = double(cob["cob"])
        }
        status.recBolus = double(loop["recommendedBolus"])

        if let predicted = loop["predicted"] as? [String: Any],
           let values = predicted["values"] as? [Double], !values.isEmpty
        {
            status.projected = values.last
            status.minBgMgdl = values.min()
            status.maxBgMgdl = values.max()
            status.predictionCurves = ["values": clamped(values)]
            status.predictionSource = .loop
        }
    }

    /// OpenAPS and Trio put the working numbers on `suggested`, which the app
    /// prefers over `enacted`, and the recommended bolus one level up.
    private static func apply(openaps: [String: Any], to status: inout NightscoutDeviceStatus) {
        if let iob = openaps["iob"] as? [String: Any] {
            status.iob = double(iob["iob"])
        }
        status.recBolus = double(openaps["recommendedBolus"])

        let block = (openaps["suggested"] as? [String: Any]) ?? (openaps["enacted"] as? [String: Any])
        guard let block else { return }

        status.cob = double(block["COB"]) ?? scraped("COB", from: block["reason"])
        status.projected = double(block["eventualBG"])
        status.autosens = double(block["sensitivityRatio"])
        status.tdd = double(block["TDD"])
        status.isfMgdlPerU = double(block["ISF"])
        status.carbRatio = double(block["CR"]) ?? scraped("CR", from: block["reason"])

        // One target, so both ends of the range carry it, the way the app does.
        // Sites configured in mmol/L post it in mmol/L, and no glucose target is
        // ever set as low as 40 mg/dL, so the small numbers are the converted ones.
        if let target = double(block["current_target"]) {
            let mgdl = target < 40 ? target * GlucoseConversion.mmolToMgDl : target
            status.targetLowMgdl = mgdl
            status.targetHighMgdl = mgdl
        }

        // oref publishes only the curves that apply, so this is often two of the
        // four and occasionally one. Each is kept whole as well as flattened for
        // the extremes: the widget builds its own envelope and needs them apart.
        if let predictions = block["predBGs"] as? [String: Any] {
            var curves = [String: [Double]]()
            for name in ["ZT", "IOB", "COB", "UAM"] {
                if let curve = predictions[name] as? [Double], !curve.isEmpty {
                    curves[name] = clamped(curve)
                }
            }
            let values = curves.values.flatMap { $0 }
            if !values.isEmpty {
                status.minBgMgdl = values.min()
                status.maxBgMgdl = values.max()
                status.predictionCurves = curves
                status.predictionSource = .openAPS
            }
        }
    }

    // MARK: - Helpers

    /// Held to the display range and to the length worth storing. The app clamps
    /// with `globalVariables`, which no extension can reach, so the bounds live
    /// on the shared type where the two writers cannot drift apart.
    private static func clamped(_ curve: [Double]) -> [Double] {
        curve.prefix(GlucosePrediction.maxSamples)
            .map { min(max($0, GlucosePrediction.minMgdl), GlucosePrediction.maxMgdl) }
    }

    /// Some of what the loop reports is only ever stated in the prose it writes
    /// alongside its numbers, so it is read out of there when the field is gone.
    private static func scraped(_ label: String, from reason: Any?) -> Double? {
        guard let reason = reason as? String,
              let range = reason.range(of: "\(label): [0-9]+(\\.[0-9]+)?", options: .regularExpression)
        else { return nil }
        return Double(reason[range].dropFirst(label.count + 2))
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Uploaders differ on whether they print fractional seconds, and a formatter
    /// that insists either way silently fails on half the sites.
    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func statusURL(baseURL: String, token: String) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.path = "/api/v1/devicestatus.json"

        var queryItems = [URLQueryItem]()
        if !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        queryItems.append(URLQueryItem(name: "count", value: "1"))
        components?.queryItems = queryItems

        return components?.url
    }
}
