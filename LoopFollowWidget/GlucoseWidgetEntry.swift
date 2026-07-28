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

    /// The reading stood, but the loop had moved on since the stored snapshot
    /// was written, so the metrics and the loop's own state were replaced. Held
    /// apart from `updated` because the age line did not reset: what is on screen
    /// is the reading that was already there, at the age it already had.
    case loopUpdated

    /// The site had nothing newer, which is the answer rather than a dead press.
    /// It says the data was checked, never that the reading is any younger.
    case upToDate
}

/// What the refresh button is drawing. The three answering states are held for a
/// few seconds only: the button has to be recognisable as a control again long
/// before anyone reaches for it a second time, so the wording under the age is
/// what carries the answer afterwards.
enum WidgetRefreshButtonPhase {
    case idle
    case justUpdated
    case justChecked
    case justFailed
    case failed
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

    /// When the refresh last reached Nightscout, whether it brought back a newer
    /// reading than the one already stored, and failing that whether it found the
    /// loop somewhere other than where the snapshot had it.
    var refreshCheckedAt: Date?
    var refreshBroughtNewData: Bool = false
    var refreshMovedLoop: Bool = false

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

    /// How long the button itself leaves its idle glyph to acknowledge the tap.
    /// Long enough that a glance away and back still catches it, short enough
    /// that the control is recognisably a refresh again well before anyone would
    /// press it a second time. The wording below the age outlasts it by design,
    /// so the answer is never gone with the glyph.
    static let buttonFlashWindow: TimeInterval = 4

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
        if refreshBroughtNewData { return .updated }
        return refreshMovedLoop ? .loopUpdated : .upToDate
    }

    /// Whether the answer to the last tap is new enough that the button is still
    /// acknowledging it rather than sitting at its idle glyph.
    var isFlashing: Bool {
        let mark = refreshDidFail ? refreshFailedAt : refreshCheckedAt
        guard let mark else { return false }
        let since = date.timeIntervalSince(mark)
        return since >= 0 && since < Self.buttonFlashWindow
    }

    /// What the button draws. The failure state outlives its flash because a tap
    /// that did not land is a standing condition rather than an acknowledgement.
    var refreshPhase: WidgetRefreshButtonPhase {
        if refreshDidFail { return isFlashing ? .justFailed : .failed }
        guard isFlashing, let refreshConfirmation else { return .idle }
        switch refreshConfirmation {
        // Green is the reading's, and the reading did not move for the other two.
        case .updated: return .justUpdated
        case .loopUpdated, .upToDate: return .justChecked
        }
    }
}
