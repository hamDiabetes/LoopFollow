// LoopFollow
// RefreshWidgetIntent.swift

import AppIntents

/// The widget's own refresh, run when the button along the base is tapped.
///
/// The reading, the chart and the forecast are rebuilt by
/// `WidgetNightscoutRefresh`, which a timeline run woken by the relay uses too.
/// What is particular to the button is here: it writes what came back into the
/// App Group, and it records enough for the widget to say what the tap did.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Glucose"
    static var description = IntentDescription("Reads the latest glucose and loop status from Nightscout.")

    /// Reached only from the widget's own button, and it needs the widget's
    /// process to write the App Group, so it neither opens the app nor offers
    /// itself as a shortcut.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        // The button is not drawn without a site to ask, so this is the case
        // where one was removed between the render and the tap.
        guard !LAAppGroupSettings.nightscoutURL().isEmpty else { return .result() }

        let stored = GlucoseSnapshotStore.shared.load()?.updatedAt ?? .distantPast

        switch await WidgetNightscoutRefresh.fetch(newerThan: stored) {
        case .unreachable:
            LAAppGroupSettings.setRefreshFailed(at: Date())
            LAAppGroupSettings.clearRefreshChecked()

        case .nothingNewer:
            // Nothing to write is still something to say: the reading and its
            // age are about to redraw as they were, and without the note the tap
            // is indistinguishable from one that did nothing at all.
            LAAppGroupSettings.setRefreshFailed(at: nil)
            LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: false)

        case let .refreshed(payload):
            // Forecast first, then the chart, then the reading. Should the
            // process be stopped part way, every prefix of that order leaves
            // something older under something newer, which is the state the
            // widget already lives in whenever its cache runs stale and which
            // its age line describes correctly. Any other order could put a
            // fresh forecast over a reading it was not computed against.
            await save(payload.prediction)
            await save(payload.series)
            await save(payload.snapshot)
            LAAppGroupSettings.setRefreshFailed(at: nil)
            LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: true)
        }

        // WidgetKit reloads the timeline once this returns, so asking it to is
        // a second reload for the same change.
        return .result()
    }

    // MARK: - Storage

    /// Both stores write on their own queue, and the widget is redrawn the moment
    /// this returns, so a fire and forget save would race the render.
    private func save(_ series: GlucoseChartSeries) async {
        await withCheckedContinuation { continuation in
            GlucoseChartSeriesStore.shared.save(series) { continuation.resume() }
        }
    }

    private func save(_ snapshot: GlucoseSnapshot) async {
        await withCheckedContinuation { continuation in
            GlucoseSnapshotStore.shared.save(snapshot) { continuation.resume() }
        }
    }

    private func save(_ prediction: GlucosePrediction?) async {
        await withCheckedContinuation { continuation in
            guard let prediction else {
                GlucosePredictionStore.shared.clear { continuation.resume() }
                return
            }
            GlucosePredictionStore.shared.save(prediction) { continuation.resume() }
        }
    }
}
