// LoopFollow
// GlucoseWidgetEntry.swift

import WidgetKit

/// One rendered state of the home screen widget.
struct GlucoseWidgetEntry: TimelineEntry {
    let date: Date
    let series: GlucoseChartSeries?
    let snapshot: GlucoseSnapshot?
    let slots: [LiveActivitySlotOption]

    /// Span of history the chart draws, chosen in Edit Widget.
    var duration: WidgetChartDuration = .standard

    /// How the readings are drawn, chosen in Edit Widget.
    var chartStyle: WidgetChartStyle = .standard

    /// Whether there is a Nightscout site for the refresh to ask. Without one,
    /// as for a Dexcom-only setup, the button has nothing to fetch and is left
    /// out rather than sitting there doing nothing.
    var canRefresh: Bool = false

    /// When the refresh button last failed to reach Nightscout, as the widget
    /// extension recorded it. Nil once a refresh has landed.
    var refreshFailedAt: Date?

    /// Clock disagreement small enough to be ordinary drift between the phone
    /// and whatever uploaded the reading.
    private static let clockSkewTolerance: TimeInterval = 60

    /// How long the button keeps saying a tap did not land. The timeline is a
    /// run of entries at advancing dates, so this is what clears the mark
    /// without a reload: the later entries simply fall outside it.
    private static let refreshFailureWindow: TimeInterval = 5 * 60

    /// Age of the reading and metrics, or nil when there is no snapshot. The
    /// Nightscout fallback renews only the series, so anything drawn from the
    /// snapshot must be judged by this, never by the chart.
    var snapshotAge: TimeInterval? {
        guard let updatedAt = snapshot?.updatedAt else { return nil }
        return max(0, date.timeIntervalSince(updatedAt))
    }

    /// A reading stamped far enough ahead of us that its age cannot be told at
    /// all: the uploader's clock is wrong, so the reading may be any age. Taken
    /// from the raw difference, since `snapshotAge` floors at zero and would
    /// report a skewed reading as brand new.
    var isTimestampAhead: Bool {
        guard let updatedAt = snapshot?.updatedAt else { return false }
        return updatedAt.timeIntervalSince(date) > Self.clockSkewTolerance
    }

    /// Whether this render should still be reporting a refresh that did not land.
    var refreshDidFail: Bool {
        guard let refreshFailedAt else { return false }
        let since = date.timeIntervalSince(refreshFailedAt)
        return since >= 0 && since < Self.refreshFailureWindow
    }
}
