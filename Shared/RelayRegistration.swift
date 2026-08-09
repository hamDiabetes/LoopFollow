// LoopFollow
// RelayRegistration.swift

import Foundation

/// Hands a push token to the relay from wherever iOS happened to issue it.
///
/// `LiveActivityRelayClient` does this for the Live Activity's tokens, but it
/// lives in the app target and leans on `Storage` and `LogManager`. The widget's
/// push token arrives in the widget extension instead, in a process that has
/// neither, and often at a moment when the app has not run for hours. So this is
/// the same registration written against nothing but Foundation and the App
/// Group, and it is what the extension calls.
enum RelayRegistration {
    /// Bumped with any change to the ContentState the relay builds. Defined here
    /// rather than in the app target so the extension sends the same number the
    /// app does; a registration the relay refuses is a device it will not push to.
    static let contentStateVersion = 1

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

    /// Forward the widget's push token.
    ///
    /// Called on every delivery rather than only on change, matching the Live
    /// Activity paths: the relay may have been reinstalled or had its registry
    /// cleared since the last one, and a token it does not hold is a widget that
    /// silently stops refreshing.
    static func submitWidgetToken(_ token: String) {
        let tail = String(token.suffix(8))

        guard LAAppGroupSettings.relayEnabled() else { return }

        let url = LAAppGroupSettings.relayURL().trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = LAAppGroupSettings.relaySecret()
        guard !url.isEmpty, !secret.isEmpty else {
            LAAppGroupSettings.setWidgetTokenAttempt(
                at: Date(),
                tokenTail: tail,
                error: RelayError.notConfigured.localizedDescription
            )
            return
        }

        guard let endpoint = URL(string: url.hasSuffix("/") ? url + "register" : url + "/register") else {
            LAAppGroupSettings.setWidgetTokenAttempt(
                at: Date(),
                tokenTail: tail,
                error: RelayError.invalidURL.localizedDescription
            )
            return
        }

        var body: [String: Any] = [
            "deviceId": LAAppGroupSettings.relayDeviceId(),
            "bundleId": LAAppGroupSettings.relayBundleId(),
            "environment": LAAppGroupSettings.relayEnvironment(),
            "contentStateVersion": contentStateVersion,
            "unit": LAAppGroupSettings.preferredUnit().rawValue,
            "widgetToken": token,
        ]
        let name = LAAppGroupSettings.relayDeviceName()
        if !name.isEmpty { body["name"] = name }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        // A widget extension is killed shortly after its work returns, and
        // `pushTokenDidChange` is not async, so the semaphore holds the process
        // alive for the round trip. Bounded well under the extension's budget:
        // a hung relay must not take the widget down with it.
        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                failure = error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse else {
                failure = "Relay gave no HTTP response"
                return
            }
            if http.statusCode != 200 {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "empty"
                failure = RelayError.rejected(status: http.statusCode, message: message).localizedDescription
            }
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            failure = "Relay did not answer within 20s"
        }

        LAAppGroupSettings.setWidgetTokenAttempt(at: Date(), tokenTail: tail, error: failure)
    }
}
