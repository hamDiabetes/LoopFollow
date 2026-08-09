// LoopFollow
// LiveActivityControlIntents.swift

import AppIntents
import WidgetKit

/// Start and stop the relay's Live Activity from Shortcuts, Siri, or a control.
///
/// These live in the widget extension deliberately. An intent hosted in the app
/// target would have iOS launch the app to service it, and a launching
/// LoopFollow evaluates its alarms — so tapping a control to put a card back
/// could sound an alarm the person never asked for. The extension carries
/// `RelayLiveActivityControl`, which needs nothing but Foundation and the App
/// Group, so nothing has to wake for a control to work.
struct StartLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Glucose Live Activity"
    static var description = IntentDescription(
        "Asks the relay to put the glucose Live Activity back on the Lock Screen."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await RelayLiveActivityControl.start()
        return .result()
    }
}

struct StopLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Hide Glucose Live Activity"
    static var description = IntentDescription(
        "Asks the relay to stop pushing the glucose Live Activity, and to leave it stopped."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        try await RelayLiveActivityControl.stop()
        return .result()
    }
}

/// What the Control Center toggle runs, and what a Shortcut uses to set the
/// state rather than flip it.
///
/// A thrown error leaves the toggle where it was, which is what should happen:
/// the relay is the authority, and a control that sprang back to "on" having
/// reported success would be claiming something it had not achieved.
struct SetLiveActivityIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Glucose Live Activity"
    static var description = IntentDescription(
        "Turns the glucose Live Activity on or off through the relay."
    )

    @Parameter(title: "Showing")
    var value: Bool

    func perform() async throws -> some IntentResult {
        if value {
            try await RelayLiveActivityControl.start()
        } else {
            try await RelayLiveActivityControl.stop()
        }
        // The control reads its own value provider, which reads the App Group
        // the calls above have just written.
        ControlCenter.shared.reloadControls(ofKind: LiveActivityControl.kind)
        return .result()
    }
}
