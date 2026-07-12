// LoopFollow
// RestartLiveActivityIntent.swift

import AppIntents
import UIKit

struct RestartLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Restart Live Activity"
    static var description = IntentDescription("Starts or restarts the LoopFollow Live Activity.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        Storage.shared.laEnabled.value = true

        let keyId = Storage.shared.lfKeyId.value
        let apnsKey = Storage.shared.lfApnsKey.value

        if keyId.isEmpty || apnsKey.isEmpty {
            if let url = URL(string: "\(AppGroupID.urlScheme)://settings/live-activity") {
                await MainActor.run { UIApplication.shared.open(url) }
            }
            return .result(dialog: "Please enter your APNs credentials in LoopFollow settings to use the Live Activity.")
        }

        await MainActor.run { LiveActivityManager.shared.forceRestart() }

        return .result(dialog: "Live Activity restarted.")
    }
}

struct StopLiveActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Live Activity"
    static var description = IntentDescription("Ends the LoopFollow Live Activity and keeps it off until restarted.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        Storage.shared.laEnabled.value = false

        await MainActor.run { LiveActivityManager.shared.end(dismissalPolicy: .immediate) }

        return .result(dialog: "Live Activity stopped.")
    }
}

struct LoopFollowAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RestartLiveActivityIntent(),
            phrases: ["Restart Live Activity in \(.applicationName)"],
            shortTitle: "Restart Live Activity",
            systemImageName: "dot.radiowaves.left.and.right",
        )
        AppShortcut(
            intent: StopLiveActivityIntent(),
            phrases: ["Stop Live Activity in \(.applicationName)"],
            shortTitle: "Stop Live Activity",
            systemImageName: "stop.circle",
        )
    }
}
