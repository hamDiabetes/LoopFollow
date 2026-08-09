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

    /// How long a rejected registration waits before being offered again. About
    /// one timeline run, so a relay that comes back up is told on its next turn
    /// rather than at whatever hour iOS next reissues a token.
    static let retryAfter: TimeInterval = 5 * 60

    /// A token the relay has already accepted is sent again this often anyway.
    /// The relay may have been reinstalled or had its registry cleared since,
    /// and a token it does not hold is a widget that silently stops refreshing.
    static let heartbeat: TimeInterval = 6 * 3600

    /// How long to leave the relay alone after a failure that looks like it is
    /// simply not on this network.
    ///
    /// The relay currently answers on a LAN address, so away from home every
    /// attempt runs to its timeout and none of them can succeed. Retrying that
    /// on each timeline run spends the extension's budget on something that
    /// cannot work, and the extension is killed if it overruns — which would
    /// cost the whole card rather than the registration.
    static let unreachableRetryAfter: TimeInterval = 6 * 3600

    /// `pushTokenDidChange` is not async and the extension is killed shortly
    /// after it returns, so that path blocks for the round trip. Registering is
    /// best-effort and drawing the card is not, so this stays far under the
    /// budget even when nothing is listening.
    private static let blockingTimeout: TimeInterval = 4

    /// A timeline run has a render waiting on it, so it gives the relay less
    /// rope still. Failing here costs a retry later and nothing else.
    private static let timelineTimeout: TimeInterval = 3

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

    // MARK: - Entry points

    /// Forward a token iOS has just issued, and keep it for later.
    ///
    /// Blocks for the round trip, because the caller is not async and the
    /// process does not outlive it.
    static func submitWidgetToken(_ token: String) {
        LAAppGroupSettings.setWidgetToken(token)

        guard LAAppGroupSettings.relayEnabled() else { return }

        let tail = String(token.suffix(8))
        let request: URLRequest
        do {
            request = try registration(for: token, timeout: blockingTimeout)
        } catch {
            LAAppGroupSettings.setWidgetTokenAttempt(
                at: Date(), tokenTail: tail, error: error.localizedDescription, unreachable: false
            )
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome = Attempt.ok

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            outcome = self.attempt(data: data, response: response, error: error)
        }
        task.resume()

        if semaphore.wait(timeout: .now() + blockingTimeout) == .timedOut {
            task.cancel()
            // Nothing answered inside the window, which is the same situation as
            // a connection error and gets the same long backoff.
            outcome = Attempt(message: "Relay did not answer within \(Int(blockingTimeout))s", unreachable: true)
        }

        LAAppGroupSettings.setWidgetTokenAttempt(
            at: Date(), tokenTail: tail, error: outcome.message, unreachable: outcome.unreachable
        )
    }

    /// Offer the stored token again if it is time to.
    ///
    /// Called from a timeline run, which is the one thing that happens on a
    /// schedule the widget can rely on. Does nothing in the ordinary case, so it
    /// is safe to call on every draw.
    static func resubmitWidgetTokenIfDue() async {
        guard LAAppGroupSettings.relayEnabled() else { return }

        let token = LAAppGroupSettings.widgetToken()
        guard !token.isEmpty, isResubmitDue() else { return }

        let tail = String(token.suffix(8))
        let request: URLRequest
        do {
            request = try registration(for: token, timeout: timelineTimeout)
        } catch {
            LAAppGroupSettings.setWidgetTokenAttempt(
                at: Date(), tokenTail: tail, error: error.localizedDescription, unreachable: false
            )
            return
        }

        var outcome = Attempt.ok
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            outcome = attempt(data: data, response: response, error: nil)
        } catch {
            outcome = attempt(data: nil, response: nil, error: error)
        }

        LAAppGroupSettings.setWidgetTokenAttempt(
            at: Date(), tokenTail: tail, error: outcome.message, unreachable: outcome.unreachable
        )
    }

    // MARK: - Policy

    /// Due when the relay has never accepted this token, when the last attempt
    /// was turned away and has had time to settle, or when the last acceptance
    /// is old enough that the relay may no longer be holding it.
    private static func isResubmitDue(now: Date = Date()) -> Bool {
        let lastAttempt = LAAppGroupSettings.widgetTokenAttemptAt()
        let lastAccepted = LAAppGroupSettings.widgetTokenAcceptedAt()
        let failed = !LAAppGroupSettings.widgetTokenError().isEmpty

        // Never offered at all. The relay's side of it is unknown, and a widget
        // the relay cannot address is the failure this whole path exists to
        // avoid, so there is nothing to wait for.
        guard let lastAttempt else { return true }

        // Nothing answered last time, so this phone is probably not on the
        // relay's network. Waiting a long while costs a stale widget in the
        // window after coming home; retrying every run costs part of every draw
        // and risks the extension being killed for overrunning, which costs the
        // card entirely.
        if LAAppGroupSettings.widgetTokenUnreachable() {
            return now.timeIntervalSince(lastAttempt) >= unreachableRetryAfter
        }

        // Turned away, or offered before this build learned to record
        // acceptance. Either way it has not been agreed to, so try again once
        // the last attempt has had time to settle.
        guard let lastAccepted, !failed else {
            return now.timeIntervalSince(lastAttempt) >= retryAfter
        }
        return now.timeIntervalSince(lastAccepted) >= heartbeat
    }

    // MARK: - Request

    private static func registration(for token: String, timeout: TimeInterval) throws -> URLRequest {
        let url = LAAppGroupSettings.relayURL().trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = LAAppGroupSettings.relaySecret()
        guard !url.isEmpty, !secret.isEmpty else { throw RelayError.notConfigured }

        guard let endpoint = URL(string: url.hasSuffix("/") ? url + "register" : url + "/register") else {
            throw RelayError.invalidURL
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
        request.timeoutInterval = timeout
        return request
    }

    /// What to record against the attempt, since the extension has no log.
    ///
    /// `unreachable` separates "nothing answered" from "something answered and
    /// said no". They call for opposite retry policies: a rejection is worth
    /// offering again shortly, while nothing answering usually means this phone
    /// is not on the relay's network and no amount of retrying will change that.
    private struct Attempt {
        let message: String?
        let unreachable: Bool

        static let ok = Attempt(message: nil, unreachable: false)
    }

    /// Codes that mean the request never reached anything, as opposed to
    /// reaching the relay and being turned away.
    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
        .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed,
        .internationalRoamingOff, .callIsActive, .dataNotAllowed,
    ]

    private static func attempt(data: Data?, response: URLResponse?, error: Error?) -> Attempt {
        if let error {
            let code = (error as? URLError)?.code
            return Attempt(
                message: error.localizedDescription,
                unreachable: code.map(unreachableCodes.contains) ?? false
            )
        }
        guard let http = response as? HTTPURLResponse else {
            return Attempt(message: "Relay gave no HTTP response", unreachable: true)
        }
        guard http.statusCode != 200 else { return .ok }
        let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "empty"
        return Attempt(
            message: RelayError.rejected(status: http.statusCode, message: message).localizedDescription,
            unreachable: false
        )
    }
}
