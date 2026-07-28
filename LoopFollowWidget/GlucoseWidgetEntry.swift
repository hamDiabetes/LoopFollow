// LoopFollow
// GlucoseWidgetEntry.swift

import Foundation
import WidgetKit

/// What a refresh that reached Nightscout has to say for itself. A widget cannot
/// redraw while its intent is running, so nothing can be shown mid fetch and the
/// render that follows carries the whole of the feedback a tap gets.
enum WidgetRefreshConfirmation {
    /// A newer reading was written. The age line resets itself, so this only has
    /// to acknowledge the tap.
    case updated

    /// The site had nothing newer, which is the answer rather than a dead press.
    /// It says the data was checked, never that the reading is any younger.
    case upToDate
}

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

    /// When the refresh last reached Nightscout, and whether it brought back a
    /// newer reading than the one already stored.
    var refreshCheckedAt: Date?
    var refreshBroughtNewData: Bool = false

    /// Clock disagreement small enough to be ordinary drift between the phone
    /// and whatever uploaded the reading.
    private static let clockSkewTolerance: TimeInterval = 60

    /// How long the button keeps saying a tap did not land. The timeline is a
    /// run of entries at advancing dates, so this is what clears the mark
    /// without a reload: the later entries simply fall outside it.
    private static let refreshFailureWindow: TimeInterval = 5 * 60

    /// How long the wording that acknowledges the tap stays up. Short, because
    /// it is an answer to a press and not a state; the provider puts an entry at
    /// the end of it so it clears on screen rather than at the next reload.
    ///
    /// Nothing in it counts, either. How long ago the check was is a fact the
    /// reading's own age already covers, and spelling it out a second time grew
    /// a line across the chart that was at its widest once it mattered least.
    static let confirmationWindow: TimeInterval = 30

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

    /// What this render should be saying about the last refresh that landed.
    /// Expires against the entry's own date, so a run of entries at advancing
    /// dates drops it without a reload.
    var refreshConfirmation: WidgetRefreshConfirmation? {
        guard !refreshDidFail, let refreshCheckedAt else { return nil }
        let since = date.timeIntervalSince(refreshCheckedAt)
        guard since >= 0, since < Self.confirmationWindow else { return nil }
        return refreshBroughtNewData ? .updated : .upToDate
    }
}
