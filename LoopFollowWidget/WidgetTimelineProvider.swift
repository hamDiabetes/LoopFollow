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
    /// long enough that a suspended app cannot hide hours of silence.
    private static let horizon: TimeInterval = 4 * 3600

    /// A minute a step for the first hour, coarsening twice after it. Nothing
    /// animates between two entries, so the step is the whole of the motion
    /// there is, and five minutes was the one interval that hides: readings
    /// arrive five minutes apart too, so the chart mapped onto itself and only
    /// the ends changed. Past the first hour the widget is being starved rather
    /// than followed, so the spacing coarsens.
    private static let fineInterval: TimeInterval = 60

    private static let entryOffsets: [TimeInterval] = {
        let fine = stride(from: 0, to: 3600, by: fineInterval).map { $0 }
        let medium = stride(from: 3600, to: 2 * 3600, by: refreshInterval).map { $0 }
        let coarse = stride(from: 2 * 3600, through: horizon, by: 15 * 60).map { $0 }
        return fine + medium + coarse
    }()

    /// Everything a tap puts on screen has to clear well inside the five minutes
    /// between the ordinary entries, so the timeline gets one extra entry at each
    /// moment one of them is due to go. Entries are what WidgetKit redraws from,
    /// and asking it for a reload on a timer is not something it grants, so an
    /// interval with no entry at its end is an interval that does not end.
    ///
    /// This is also what guarantees each state a minimum time on screen. The
    /// deadlines are seconds apart while the ordinary run is minutes apart, so a
    /// state cannot be skipped by a redraw that lands between them.
    private static func offsets(expiringIn deadlines: [TimeInterval?]) -> [TimeInterval] {
        let extra = deadlines
            .compactMap { $0 }
            .filter { $0 > 0 && $0 < horizon && !entryOffsets.contains($0) }
        guard !extra.isEmpty else { return entryOffsets }
        return (entryOffsets + extra).sorted()
    }

    /// The refresh fetches from Nightscout, so a setup without one has nothing
    /// for the button to do.
    private static var canRefresh: Bool {
        !LAAppGroupSettings.nightscoutURL().isEmpty
    }

    func placeholder(in _: Context) -> GlucoseWidgetEntry {
        Self.sampleEntry(slots: LiveActivitySlotDefaults.widget, duration: .standard, style: .standard, horizon: .standard)
    }

    func snapshot(for configuration: GlucoseWidgetConfigurationIntent, in context: Context) async -> GlucoseWidgetEntry {
        if context.isPreview {
            return Self.sampleEntry(
                slots: configuration.slots,
                duration: configuration.duration,
                style: configuration.chartStyle,
                horizon: configuration.predictionHorizon
            )
        }
        let (series, snapshot, prediction) = await WidgetDataSource.load()
        return GlucoseWidgetEntry(
            date: Date(),
            series: series,
            snapshot: snapshot,
            slots: configuration.slots,
            duration: configuration.duration,
            chartStyle: configuration.chartStyle,
            prediction: prediction,
            predictionHorizon: configuration.predictionHorizon,
            canRefresh: Self.canRefresh,
            refreshFailedAt: LAAppGroupSettings.refreshFailedAt(),
            refreshCheckedAt: LAAppGroupSettings.refreshCheckedAt(),
            refreshBroughtNewData: LAAppGroupSettings.refreshBroughtNewData()
        )
    }

    func timeline(for configuration: GlucoseWidgetConfigurationIntent, in _: Context) async -> Timeline<GlucoseWidgetEntry> {
        let now = Date()
        let (series, snapshot, prediction) = await WidgetDataSource.load()
        // Read once and carried on every entry, so the later ones age out of the
        // failure window on their own rather than needing a reload to clear it.
        let refreshFailedAt = LAAppGroupSettings.refreshFailedAt()
        let refreshCheckedAt = LAAppGroupSettings.refreshCheckedAt()
        let refreshBroughtNewData = LAAppGroupSettings.refreshBroughtNewData()
        let canRefresh = Self.canRefresh

        // One deadline per thing a tap leaves on screen: the button's own
        // acknowledgement, and the wording that outlasts it.
        let deadlines: [TimeInterval?] = [
            refreshCheckedAt?.addingTimeInterval(GlucoseWidgetEntry.confirmationWindow).timeIntervalSince(now),
            refreshCheckedAt?.addingTimeInterval(GlucoseWidgetEntry.buttonFlashWindow).timeIntervalSince(now),
            refreshFailedAt?.addingTimeInterval(GlucoseWidgetEntry.buttonFlashWindow).timeIntervalSince(now),
        ]

        let entries = Self.offsets(expiringIn: deadlines).map { offset in
            GlucoseWidgetEntry(
                date: now.addingTimeInterval(offset),
                series: series,
                snapshot: snapshot,
                slots: configuration.slots,
                duration: configuration.duration,
                chartStyle: configuration.chartStyle,
                prediction: prediction,
                predictionHorizon: configuration.predictionHorizon,
                canRefresh: canRefresh,
                refreshFailedAt: refreshFailedAt,
                refreshCheckedAt: refreshCheckedAt,
                refreshBroughtNewData: refreshBroughtNewData
            )
        }

        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshInterval)))
    }

    // MARK: - Gallery sample

    private static func sampleEntry(
        slots: [LiveActivitySlotOption],
        duration: WidgetChartDuration,
        style: WidgetChartStyle,
        horizon: WidgetPredictionHorizon
    ) -> GlucoseWidgetEntry {
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

        // Two curves that part company, which is what an envelope worth drawing
        // looks like: insulin on board pulling down against a zero temp that
        // barely moves. Carried on the gallery entry so picking a horizon in
        // Edit Widget shows what it does before the widget is placed.
        let prediction = GlucosePrediction(
            curves: [
                "ZT": [124, 123, 122, 121, 120, 119, 118, 118, 117, 117, 116, 116, 115],
                "IOB": [124, 120, 115, 109, 103, 97, 92, 88, 85, 83, 82, 81, 81],
            ],
            source: .openAPS,
            anchor: now,
            updatedAt: now
        )

        return GlucoseWidgetEntry(
            date: now,
            series: GlucoseChartSeries(points: points, updatedAt: now),
            snapshot: snapshot,
            slots: slots,
            duration: duration,
            chartStyle: style,
            prediction: prediction,
            predictionHorizon: horizon,
            canRefresh: canRefresh
        )
    }
}
