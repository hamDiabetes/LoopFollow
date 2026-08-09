// LoopFollow
// LiveActivityRelayClient.swift

// swiftformat:disable indent
#if !targetEnvironment(macCatalyst)

import Foundation
import UIKit

/// Hands the Live Activity's push tokens to an external relay.
///
/// The relay watches Nightscout and pushes the Live Activity from outside the
/// phone, which is the only way it stays current while iOS has stopped this app.
/// Nothing here pushes anything itself; it only forwards the tokens iOS issues,
/// and it does nothing at all while the relay is switched off.
final class LiveActivityRelayClient {
    static let shared = LiveActivityRelayClient()
    private init() {}

    /// Bumped with any change to the ContentState the relay builds. The relay
    /// refuses a registration whose version it does not recognise: a mismatched
    /// shape blanks fields on the Live Activity rather than failing anywhere a
    /// person would see it. Defined in Shared so the widget extension, which
    /// registers its own token, cannot drift to a different number.
    static let contentStateVersion = RelayRegistration.contentStateVersion

    enum RelayError: LocalizedError {
        case notConfigured
        case invalidURL
        case rejected(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Relay URL or secret is not set"
            case .invalidURL: return "Relay URL is not a valid URL"
            case let .rejected(status, message): return "Relay returned \(status): \(message)"
            }
        }
    }

    /// Stable per-install identifier so the relay can tell two phones apart and
    /// rotate each one's tokens independently. `identifierForVendor` is reissued
    /// on reinstall, which is the right granularity: a reinstall's tokens are new too.
    private var deviceId: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    /// A TestFlight or App Store build's tokens are only valid against production
    /// APNs, and a development build's only against sandbox. The relay has to be
    /// told which, because pushing to the wrong host fails silently from its side.
    private var environment: String {
        BuildDetails.default.isTestFlightBuild() ? "production" : "sandbox"
    }

    private var isConfigured: Bool {
        Storage.shared.laRelayEnabled.value
            && !Storage.shared.laRelayURL.value.isEmpty
            && !Storage.shared.laRelaySecret.value.isEmpty
    }

    /// Copies everything an extension needs to register on its own into the App
    /// Group. The widget's push token is delivered to the widget extension, which
    /// cannot read `Storage` and may run when the app has not been alive for
    /// hours, so this has to be in place before the token arrives rather than
    /// fetched when it does.
    func mirrorSettingsForExtensions() {
        LAAppGroupSettings.setRelay(
            enabled: Storage.shared.laRelayEnabled.value,
            url: Storage.shared.laRelayURL.value,
            secret: Storage.shared.laRelaySecret.value,
            deviceId: deviceId,
            bundleId: Bundle.main.bundleIdentifier ?? "",
            environment: environment,
            deviceName: UIDevice.current.name
        )
    }

    /// Forward whichever tokens have changed.
    ///
    /// Both are optional because they arrive on separate streams and rotate on
    /// their own schedules — a registration carrying one leaves the other alone.
    func register(updateToken: String?, pushToStartToken: String?) {
        // Kept current here as well as on the settings screen: the widget's token
        // can arrive at any time, and a mirror written once at setup would go
        // stale the first time the secret or the URL changed.
        mirrorSettingsForExtensions()
        guard Storage.shared.laRelayEnabled.value else { return }
        guard isConfigured else {
            LogManager.shared.log(category: .apns, message: "[relay] enabled but URL or secret missing — not registering")
            Storage.shared.laRelayLastError.value = RelayError.notConfigured.localizedDescription
            return
        }
        // iOS issues push tokens only once a Live Activity exists, so enabling the
        // relay before starting one leaves nothing to send. Say so: silence here
        // is indistinguishable from a failed POST, and the settings screen would
        // read "Never" with no explanation for why.
        guard updateToken != nil || pushToStartToken != nil else {
            LogManager.shared.log(category: .apns, message: "[relay] no tokens yet — start the Live Activity first")
            Storage.shared.laRelayLastError.value =
                "Waiting for iOS to issue a push token. Enable the Live Activity, then this registers on its own."
            return
        }

        Task { await send(updateToken: updateToken, pushToStartToken: pushToStartToken) }
    }

    private func send(updateToken: String?, pushToStartToken: String?) async {
        let base = Storage.shared.laRelayURL.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? base + "register" : base + "/register") else {
            LogManager.shared.log(category: .apns, message: "[relay] invalid relay URL")
            Storage.shared.laRelayLastError.value = RelayError.invalidURL.localizedDescription
            return
        }

        var body: [String: Any] = [
            "deviceId": deviceId,
            "bundleId": Bundle.main.bundleIdentifier ?? "",
            "environment": environment,
            "contentStateVersion": LiveActivityRelayClient.contentStateVersion,
            "unit": PreferredGlucoseUnit.snapshotUnit().rawValue,
            "name": UIDevice.current.name,
        ]
        if let updateToken { body["updateToken"] = updateToken }
        if let pushToStartToken { body["pushToStartToken"] = pushToStartToken }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(Storage.shared.laRelaySecret.value)", forHTTPHeaderField: "authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        // Token rotation is exactly when iOS grants background runtime, so a
        // registration usually has a moment to complete. Failures are recorded
        // rather than retried here: the next token delivery re-registers, and a
        // stale registration surfaces in settings instead of retrying silently.
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            let which = [updateToken != nil ? "update" : nil, pushToStartToken != nil ? "push-to-start" : nil]
                .compactMap { $0 }
                .joined(separator: "+")

            if http.statusCode == 200 {
                Storage.shared.laRelayLastRegisteredAt.value = Date().timeIntervalSince1970
                Storage.shared.laRelayLastError.value = ""
                LogManager.shared.log(category: .apns, message: "[relay] registered \(which) token(s)")
            } else {
                let message = String(data: data, encoding: .utf8) ?? "empty"
                let error = RelayError.rejected(status: http.statusCode, message: message)
                Storage.shared.laRelayLastError.value = error.localizedDescription
                LogManager.shared.log(category: .apns, message: "[relay] registration refused: \(error.localizedDescription)")
            }
        } catch {
            Storage.shared.laRelayLastError.value = error.localizedDescription
            LogManager.shared.log(category: .apns, message: "[relay] registration failed: \(error.localizedDescription)")
        }
    }
}

#endif
