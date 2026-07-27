// LoopFollow
// WidgetTimelineProvider.swift

import WidgetKit

/// Supplies the home screen widget from the App Group caches written by the app.
///
/// Entries carry the same data at advancing dates, so the reading keeps aging
/// into its stale state even when WidgetKit cannot afford to reload us.
struct WidgetTimelineProvider: AppIntentTimelineProvider {
    private static let refreshInterval: TimeInterval = 5 * 60

    /// WidgetKit keeps drawing the last entry once the timeline runs out, so a
    /// short timeline makes an old reading claim to be recent. Cover a stretch
    /// long enough that a suspended app cannot hide hours of silence: every five
    /// minutes for the first hour, then every fifteen out to the horizon.
    private static let horizon: TimeInterval = 4 * 3600

    private static let entryOffsets: [TimeInterval] = {
        let fine = stride(from: 0, to: 3600, by: refreshInterval).map { $0 }
        let coarse = stride(from: 3600, through: horizon, by: 15 * 60).map { $0 }
        return fine + coarse
    }()

    func placeholder(in _: Context) -> GlucoseWidgetEntry {
        Self.sampleEntry(slots: LiveActivitySlotDefaults.all, duration: .standard)
    }

    func snapshot(for configuration: GlucoseWidgetConfigurationIntent, in context: Context) async -> GlucoseWidgetEntry {
        if context.isPreview {
            return Self.sampleEntry(slots: configuration.slots, duration: configuration.duration)
        }
        let (series, snapshot) = await WidgetDataSource.load()
        return GlucoseWidgetEntry(date: Date(), series: series, snapshot: snapshot, slots: configuration.slots, duration: configuration.duration)
    }

    func timeline(for configuration: GlucoseWidgetConfigurationIntent, in _: Context) async -> Timeline<GlucoseWidgetEntry> {
        let now = Date()
        let (series, snapshot) = await WidgetDataSource.load()

        let lastOffset = Self.entryOffsets.last
        let entries = Self.entryOffsets.map { offset in
            GlucoseWidgetEntry(
                date: now.addingTimeInterval(offset),
                series: series,
                snapshot: snapshot,
                slots: configuration.slots,
                duration: configuration.duration,
                isLast: offset == lastOffset
            )
        }

        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshInterval)))
    }

    // MARK: - Gallery sample

    private static func sampleEntry(slots: [LiveActivitySlotOption], duration: WidgetChartDuration) -> GlucoseWidgetEntry {
        let now = Date()
        // Spread across whatever span was picked, so the gallery preview fills
        // its chart at every duration.
        let values: [Double] = [96, 104, 112, 118, 121, 126, 133, 141, 148, 152, 149, 142, 136, 131, 127, 124]
        let spacing = duration.seconds / Double(values.count)
        let points = values.enumerated().map { index, value in
            GlucoseChartPoint(value: value, date: now.addingTimeInterval(Double(index - values.count + 1) * spacing))
        }

        let snapshot = GlucoseSnapshot(
            glucose: 124,
            delta: -3,
            trend: .downSlight,
            updatedAt: now,
            iob: 1.2,
            cob: 18,
            projected: 118,
            recBolus: 0.35,
            basalRate: "0.75 U/hr",
            tdd: 24.6,
            targetLowMgdl: 100,
            targetHighMgdl: 100,
            unit: .mgdl,
            isNotLooping: false
        )

        return GlucoseWidgetEntry(
            date: now,
            series: GlucoseChartSeries(points: points, updatedAt: now),
            snapshot: snapshot,
            slots: slots,
            duration: duration
        )
    }
}
