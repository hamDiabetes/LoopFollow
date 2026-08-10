// LoopFollow
// LiveActivityFocusFilter.swift

import AppIntents

/// Lets a Focus mode decide whether the glucose Live Activity is showing.
///
/// Sleep is the case worth having: the card is what a caregiver checks at night,
/// and the person who wants it hidden during Work is usually the same person who
/// wants it back the moment Sleep begins. A Focus Filter says that once in
/// Settings rather than as two personal automations that can drift apart.
struct LiveActivityFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Glucose Live Activity"
    static var description = IntentDescription(
        "Show or hide the glucose Live Activity while this Focus is on."
    )

    @Parameter(title: "Show Live Activity", default: true)
    var showLiveActivity: Bool

    /// What Settings shows under the Focus, so a glance says which way round it
    /// is without opening the filter.
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: showLiveActivity ? "Live Activity showing" : "Live Activity hidden"
        )
    }

    /// A Focus can end while the phone is locked and the app is not running, so
    /// this goes the same way every other control does — straight to the relay,
    /// through the App Group, waking nothing.
    func perform() async throws -> some IntentResult {
        if showLiveActivity {
            try await RelayLiveActivityControl.start(source: .focus)
        } else {
            try await RelayLiveActivityControl.stop(source: .focus)
        }
        return .result()
    }
}
