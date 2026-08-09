// LoopFollow
// RelayLiveActivityControl.swift

import Foundation

/// Turns the relay's Live Activity on and off from wherever the request came.
///
/// The relay owns the card while it is enabled — the app cannot create one, only
/// ask for one — so a control that starts and stops it is a pair of requests to
/// the relay rather than anything ActivityKit does locally. This is written
/// against Foundation and the App Group alone, like `RelayRegistration`, because
/// the controls that matter are the ones reachable when the app is not running:
/// a Control Center tap, a Shortcut, a Focus mode changing.
enum RelayLiveActivityControl {
    /// A control has a person waiting on it, and a widget extension is killed if
    /// it overruns. Long enough for a relay on the same network, short enough
    /// that being away from home fails quickly rather than hanging the tap.
    private static let timeout: TimeInterval = 5

    enum ControlError: LocalizedError {
        case notConfigured
        case invalidURL
        case refused(status: Int)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "The relay is not set up on this phone."
            case .invalidURL:
                return "The relay address is not a valid URL."
            case let .refused(status):
                return "The relay refused the request (\(status))."
            case let .unreachable(detail):
                return "Could not reach the relay: \(detail)"
            }
        }
    }

    // MARK: - Requests

    /// Ask the relay to create a Live Activity, and clear any pause.
    ///
    /// The relay treats an explicit start as unambiguous and unpauses on it, so
    /// this is one round trip rather than two — which matters because iOS may
    /// only give the caller time for one.
    static func start() async throws {
        try await post(path: "push?start=1", body: nil)
        LAAppGroupSettings.setLiveActivityPaused(false)
    }

    /// Ask the relay to stop pushing, and to leave it stopped.
    ///
    /// The local state is only written after the relay has agreed. If this
    /// throws, the caller has a card it could not switch off — which is the
    /// right way round: a card left up when someone wanted it gone is an
    /// annoyance, and one taken down while the relay carries on believing it
    /// switched nothing off is a caregiver missing a glucose display.
    static func stop() async throws {
        try await post(path: "pause", body: ["deviceId": deviceId, "paused": true])
        LAAppGroupSettings.setLiveActivityPaused(true)
    }

    // MARK: - State

    /// What the toggle draws, and what a Shortcut reads back.
    ///
    /// The relay is the authority and this is a local echo of the last agreed
    /// answer, so it is right whenever a request succeeded and stale only when
    /// one failed — at which point the error is surfaced rather than swallowed.
    static var isOn: Bool {
        LAAppGroupSettings.relayEnabled() && !LAAppGroupSettings.liveActivityPaused()
    }

    private static var deviceId: String {
        LAAppGroupSettings.relayDeviceId()
    }

    // MARK: - Transport

    private static func post(path: String, body: [String: Any]?) async throws {
        guard LAAppGroupSettings.relayEnabled() else { throw ControlError.notConfigured }

        let base = LAAppGroupSettings.relayURL().trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = LAAppGroupSettings.relaySecret()
        guard !base.isEmpty, !secret.isEmpty, !deviceId.isEmpty else { throw ControlError.notConfigured }
        guard let url = URL(string: (base.hasSuffix("/") ? base : base + "/") + path) else {
            throw ControlError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ControlError.unreachable("no HTTP response")
            }
            guard http.statusCode == 200 else { throw ControlError.refused(status: http.statusCode) }
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError.unreachable(error.localizedDescription)
        }
    }
}
