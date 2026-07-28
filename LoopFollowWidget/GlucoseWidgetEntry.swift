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

    /// Age of the reading and metrics, or nil when there is no snapshot. The
    /// Nightscout fallback renews only the series, so anything drawn from the
    /// snapshot must be judged by this, never by the chart.
    var snapshotAge: TimeInterval? {
        guard let updatedAt = snapshot?.updatedAt else { return nil }
        return max(0, date.timeIntervalSince(updatedAt))
    }
}
