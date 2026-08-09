// LoopFollow
// LiveActivityControl.swift

import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center and Lock Screen toggle for the glucose Live Activity.
///
/// The card is the thing a caregiver reads, and putting it back had meant
/// opening the app and finding a button four screens into Settings. This is one
/// tap from the Lock Screen without launching anything.
struct LiveActivityControl: ControlWidget {
    static let kind = "\(Bundle.main.bundleIdentifier ?? "LoopFollow").LiveActivityControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle(
                "Glucose",
                isOn: isOn,
                action: SetLiveActivityIntent()
            ) { showing in
                Image(systemName: showing ? "drop.fill" : "drop")
                Text(showing ? "Showing" : "Hidden")
            }
        }
        .displayName("Glucose Live Activity")
        .description("Show or hide the glucose Live Activity.")
    }

    struct Provider: ControlValueProvider {
        /// Drawn before the App Group has been read. On rather than off, so the
        /// control never briefly claims the card has been switched off when it
        /// has not.
        let previewValue = true

        func currentValue() async throws -> Bool {
            RelayLiveActivityControl.isOn
        }
    }
}
