// LoopFollow
// LAChart.swift

import Foundation

/// The glucose history and forecast carried in a Live Activity push.
///
/// The Live Activity cannot read the App Group chart cache the widget uses: the
/// app writes that file, and the app being asleep is the reason a relay exists
/// at all. So the readings travel in the payload, and this is the shape they
/// arrive in.
///
/// Slotted rather than listed. Readings are already on a five-minute grid, so
/// an anchor, a step and one value per slot costs a fraction of what a
/// timestamp per point would, and the whole payload has 4KB to live in.
///
/// A slot with no reading is nil. It is never omitted and never filled in: the
/// chart splits its line at a twenty-minute gap, and a sensor outage arriving
/// as adjacent readings would draw as an unbroken trace across readings that
/// were never taken.
struct LAChart: Codable, Hashable {
    /// Epoch seconds of slot zero.
    let anchor: Double

    /// Seconds between slots.
    let step: Double

    /// mg/dL per slot, oldest first, nil where no reading was taken.
    let values: [Int?]

    /// Epoch seconds of the loop cycle the forecast runs forward from, which is
    /// not when the push was built.
    let predictionAnchor: Double?

    /// The spread across the curves the loop published, as one low and one high
    /// per sample. The chart's only use for the curves is this envelope, so the
    /// relay computes it rather than sending four curves to have them reduced
    /// on arrival. Equal low and high is a forecast with no width, which the
    /// chart already draws as a line rather than a cone.
    let low: [Int]?
    let high: [Int]?

    /// The readings, in the form the chart draws.
    ///
    /// Timestamps are rebuilt from the slot index, so a gap stays a gap: the
    /// points either side of it are the full interval apart and nothing is
    /// invented in between.
    var series: GlucoseChartSeries? {
        let points = values.enumerated().compactMap { index, value -> GlucoseChartPoint? in
            guard let value else { return nil }
            return GlucoseChartPoint(
                value: Double(value),
                date: Date(timeIntervalSince1970: anchor + Double(index) * step)
            )
        }
        guard let newest = points.last else { return nil }
        return GlucoseChartSeries(points: points, updatedAt: newest.date)
    }

    /// The forecast, rebuilt as the two curves whose per-index spread is the
    /// envelope that was sent. `bands(upTo:)` takes the minimum and maximum
    /// across curves, so it returns exactly the low and high it was given.
    var prediction: GlucosePrediction? {
        guard let predictionAnchor, let low, let high, low.count == high.count, low.count > 1 else {
            return nil
        }
        return GlucosePrediction(
            curves: ["low": low.map(Double.init), "high": high.map(Double.init)],
            source: .openAPS,
            anchor: Date(timeIntervalSince1970: predictionAnchor),
            updatedAt: Date(timeIntervalSince1970: predictionAnchor)
        )
    }

    /// The moment the newest reading in this chart was taken, which is what the
    /// chart measures its window back from.
    var newestReadingAt: Date? {
        guard let lastIndex = values.lastIndex(where: { $0 != nil }) else { return nil }
        return Date(timeIntervalSince1970: anchor + Double(lastIndex) * step)
    }

    /// Spacing the readings and the forecast are both published at.
    static let standardStep: TimeInterval = 300

    /// Build from what the app has cached, for the updates the app sends itself.
    ///
    /// The relay is not the only writer: with it switched off the app drives its
    /// own Live Activity, and without this that path would send no chart and the
    /// lock screen would lose its background. Slotted the same way the relay
    /// does it, anchored on the newest reading so that accumulated drift is
    /// spent on the oldest ones rather than on the readings being acted on.
    init?(series: GlucoseChartSeries?, prediction: GlucosePrediction?, window: TimeInterval) {
        guard let series, let newest = series.points.last else { return nil }

        let step = Self.standardStep
        let cutoff = newest.date.addingTimeInterval(-window)
        let drawn = series.points.filter { $0.date >= cutoff }
        guard let oldest = drawn.first else { return nil }

        let slots = Int(((newest.date.timeIntervalSince1970 - oldest.date.timeIntervalSince1970) / step).rounded()) + 1
        let anchorTime = newest.date.timeIntervalSince1970 - Double(slots - 1) * step

        var slotted = [Int?](repeating: nil, count: slots)
        var placed = [TimeInterval?](repeating: nil, count: slots)
        for point in drawn {
            let index = Int(((point.date.timeIntervalSince1970 - anchorTime) / step).rounded())
            guard index >= 0, index < slots else { continue }
            let slotTime = anchorTime + Double(index) * step
            if let existing = placed[index],
               abs(point.date.timeIntervalSince1970 - slotTime) >= abs(existing - slotTime)
            {
                continue
            }
            slotted[index] = Int(point.value.rounded())
            placed[index] = point.date.timeIntervalSince1970
        }

        anchor = anchorTime
        self.step = step
        values = slotted

        // Reduced to the same envelope the relay sends, so both producers put
        // the identical shape on screen rather than two that drift apart.
        let bands = prediction.map { $0.bands(upTo: $0.anchor.addingTimeInterval(window)) } ?? []
        if bands.count > 1, let predictionSource = prediction {
            predictionAnchor = predictionSource.anchor.timeIntervalSince1970
            low = bands.map { Int($0.low.rounded()) }
            high = bands.map { Int($0.high.rounded()) }
        } else {
            predictionAnchor = nil
            low = nil
            high = nil
        }
    }
}
