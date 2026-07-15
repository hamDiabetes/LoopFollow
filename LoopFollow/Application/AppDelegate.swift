// LoopFollow
// AppDelegate.swift

import AVFoundation
import UIKit
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    let notificationCenter = UNUserNotificationCenter.current()

    /// Category Trio sets on a "recommended bolus" response; must match Trio's identifier.
    static let recommendedBolusCategoryIdentifier = "TRIO_RECOMMENDED_BOLUS"
    /// Action on that category that opens the bolus screen pre-filled for review.
    static let reviewBolusActionIdentifier = "REVIEW_BOLUS"

    /// The app's full set of notification categories. Single source of truth so every caller of
    /// setNotificationCategories (which replaces the whole set) registers all of them — otherwise a caller
    /// that sets only its own category silently de-registers the others.
    static func baseNotificationCategories() -> [UNNotificationCategory] {
        let openAction = UNNotificationAction(identifier: "OPEN_APP_ACTION", title: "Open App", options: .foreground)
        let backgroundCategory = UNNotificationCategory(
            identifier: BackgroundAlertIdentifier.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )

        // Category for a Trio "recommended bolus" response. The Review action (and tapping the body) opens
        // the bolus screen pre-filled; .authenticationRequired keeps it behind device unlock.
        let reviewAction = UNNotificationAction(
            identifier: reviewBolusActionIdentifier,
            title: "Review",
            options: [.foreground, .authenticationRequired]
        )
        let recommendedBolusCategory = UNNotificationCategory(
            identifier: recommendedBolusCategoryIdentifier,
            actions: [reviewAction],
            intentIdentifiers: [],
            options: []
        )

        return [backgroundCategory, recommendedBolusCategory]
    }

    /// Removes any delivered "recommended bolus" notifications so a recommendation can't be tapped or
    /// confirmed twice from Notification Center after it has been acted on or has expired.
    static func removeDeliveredRecommendedBolusNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiers = notifications
                .filter { $0.request.content.categoryIdentifier == recommendedBolusCategoryIdentifier }
                .map { $0.request.identifier }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LogManager.shared.log(category: .general, message: "App started")
        LogManager.shared.cleanupOldLogs()

        // Notification and calendar permissions are no longer requested here.
        // They're deferred to the moment the user opts into the feature that
        // needs them (alarms request notifications via NotificationAuthorization;
        // the Calendar settings screen requests calendar access), so a fresh
        // install isn't fronted with permission prompts before onboarding.

        // Before-First-Unlock detection. isProtectedDataAvailable is false on ANY
        // locked launch, so it alone isn't a BFU signal — post-first-unlock
        // UserDefaults (class C) reads fine while locked. Only true BFU makes a key
        // that should exist read as absent. Suspect only when ALL presence probes
        // are absent, so an existing user who updated but hasn't foregrounded this
        // build isn't misread on an ordinary locked launch. Probes cover every user
        // shape (marker / migrated / consented / NS-configured); presence, not value.
        _ = Storage.shared // ensure every StorageValue is registered before recovery
        let storageConfirmedReadable = StorageReadiness.markerExists
            || Storage.shared.migrationStep.exists
            || Storage.shared.telemetryConsentDecisionMade.exists
            || Storage.shared.url.exists
        let suspectBFU = !UIApplication.shared.isProtectedDataAvailable && !storageConfirmedReadable
        StorageReadiness.configure(suspectBFU: suspectBFU)
        LogManager.shared.log(category: .general, message: "BFU check: isProtectedDataAvailable=\(UIApplication.shared.isProtectedDataAvailable), storageConfirmedReadable=\(storageConfirmedReadable), suspectBFU=\(suspectBFU)")

        if suspectBFU {
            // Driven here, not MainViewController: on a BG-only launch (BGAppRefreshTask,
            // BLE wake) the home VC may not exist yet. protectedDataDidBecomeAvailable is
            // authoritative; willEnterForeground is a fallback.
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(protectedDataDidBecomeAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
            nc.addObserver(self, selector: #selector(handleWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

            // Race guard: protected data may have become available between the check
            // above and the observer registration just now.
            if UIApplication.shared.isProtectedDataAvailable {
                completeStorageRecovery()
            }
        }

        UNUserNotificationCenter.current().setNotificationCategories(Set(AppDelegate.baseNotificationCategories()))

        UNUserNotificationCenter.current().delegate = self

        // Only spin up Bluetooth if the user has chosen a BLE-based background
        // refresh. Initializing BLEManager creates a CBCentralManager, which
        // triggers the Bluetooth permission prompt — deferring it keeps that
        // prompt off fresh installs until the feature is actually enabled.
        if Storage.shared.backgroundRefreshType.value.isBluetooth {
            _ = BLEManager.shared
        }
        // Ensure VolumeButtonHandler is initialized so it can receive alarm notifications
        _ = VolumeButtonHandler.shared

        // Register for remote notifications
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }

        BackgroundRefreshManager.shared.register()

        // Telemetry mutates rolling history (coldLaunches7d), so defer past a BFU
        // window — poisoned defaults would discard real history. Runs synchronously
        // on a normal launch.
        StorageReadiness.whenReady {
            // SHA change fires an immediate ping (the scheduler can't notice an app
            // update); otherwise the 24h scheduler handles cadence. See Telemetry.swift.
            TelemetryClient.shared.recordColdLaunch()
            Task.detached {
                if TelemetryClient.shared.buildShaChangedSinceLastSend() {
                    await TelemetryClient.shared.maybeSend()
                }
                TelemetryClient.shared.scheduleRecurring()
            }
        }

        return true
    }

    // MARK: - BFU recovery

    @objc private func protectedDataDidBecomeAvailable() {
        completeStorageRecovery()
    }

    @objc private func handleWillEnterForeground() {
        completeStorageRecovery()
    }

    private func completeStorageRecovery() {
        // recover() hydrates every value and opens the gate; true only on the one
        // transition that did the work, so the notification fires exactly once.
        guard StorageReadiness.recover() else { return }
        LogManager.shared.log(category: .general, message: "BFU recovery complete: url='\(Storage.shared.url.value)'")
        NotificationCenter.default.post(name: .bfuReloadCompleted, object: nil)
    }

    func applicationWillTerminate(_: UIApplication) {
        #if !targetEnvironment(macCatalyst)
            LiveActivityManager.shared.endOnTerminate()
        #endif
    }

    // MARK: - Remote Notifications

    /// Called when successfully registered for remote notifications
    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()

        Observable.shared.loopFollowDeviceToken.value = tokenString

        LogManager.shared.log(category: .apns, message: "Successfully registered for remote notifications with token: \(LogRedactor.tail(tokenString))")
    }

    /// Called when failed to register for remote notifications
    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        LogManager.shared.log(category: .apns, message: "Failed to register for remote notifications: \(error.localizedDescription)")
    }

    /// Called when a remote notification is received
    func application(_: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let userInfoKeys = userInfo.keys.compactMap { $0 as? String }.sorted()
        LogManager.shared.log(category: .apns, message: "Received remote notification: keys=\(userInfoKeys)")

        // Check if this is a response notification from Loop or Trio
        if let aps = userInfo["aps"] as? [String: Any] {
            // Handle visible notification (alert, sound, badge)
            if let alert = aps["alert"] as? [String: Any] {
                let title = alert["title"] as? String ?? ""
                let body = alert["body"] as? String ?? ""
                LogManager.shared.log(category: .apns, message: "Notification - Title: \(title), Body: \(body)")
            }

            // Handle silent notification (content-available)
            if let contentAvailable = aps["content-available"] as? Int, contentAvailable == 1 {
                // This is a silent push, nothing implemented but logging for now

                if let commandStatus = userInfo["command_status"] as? String {
                    LogManager.shared.log(category: .apns, message: "Command status: \(commandStatus)")
                }

                if let commandType = userInfo["command_type"] as? String {
                    LogManager.shared.log(category: .apns, message: "Command type: \(commandType)")
                }
            }
        }

        // Call completion handler
        completionHandler(.newData)
    }

    func application(_: UIApplication, willFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UIApplication.shared.isIdleTimerDisabled = Storage.shared.screenlockSwitchState.value
        return true
    }

    // MARK: - Scene configuration

    // Under the scene-based lifecycle (which the SwiftUI App lifecycle uses),
    // UIKit delivers Home Screen quick actions and opened URLs to the window
    // scene delegate — application(_:performActionFor:) is never called.
    // Injecting a delegate class here is the supported way to receive those
    // events; SwiftUI still creates and manages the window itself.
    func application(_: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options _: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = AppSceneDelegate.self
        }
        return configuration
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "OPEN_APP_ACTION" {
            // Dismiss any presented modal/sheet so the user actually sees Home
            UIApplication.shared.topMost?.dismiss(animated: true)
            Observable.shared.selectedTabIndex.value = 0
        }

        if response.actionIdentifier == "snooze" {
            AlarmManager.shared.performSnooze()
        }

        // A Trio "recommended bolus" review: tapping the body or the Review action opens the bolus screen
        // pre-filled; the user still confirms via Face ID and the guardrails, so nothing is dosed here.
        if response.actionIdentifier == AppDelegate.reviewBolusActionIdentifier
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        {
            if let request = AppDelegate.reviewBolusRequest(from: response.notification.request.content.userInfo) {
                // Presented from the tab root; MainTabView defers behind the first-launch consent sheet.
                DispatchQueue.main.async {
                    Observable.shared.pendingReviewBolus.value = request
                }
            }
        }

        completionHandler()
    }

    /// Builds a review request from Trio's structured `recommended_bolus` field (units) and the response's
    /// `timestamp` (send time). APNs delivers JSON numbers as NSNumber; strings are accepted defensively.
    /// Returns nil when the amount is absent or not positive.
    static func reviewBolusRequest(from userInfo: [AnyHashable: Any]) -> ReviewBolusRequest? {
        func double(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }

        guard let amount = double(userInfo["recommended_bolus"]), amount > 0 else { return nil }
        let sentAt = double(userInfo["timestamp"]) ?? Date().timeIntervalSince1970
        return ReviewBolusRequest(amount: amount, sentAt: sentAt)
    }

    func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
        let forcePortrait = Storage.shared.forcePortraitMode.value

        if forcePortrait {
            return .portrait
        } else {
            return .all
        }
    }
}

extension Notification.Name {
    /// Posted by AppDelegate after a Before-First-Unlock recovery completes
    /// (StorageReadiness.recover has hydrated every value from the now-decrypted
    /// UserDefaults).
    static let bfuReloadCompleted = Notification.Name("LoopFollow.bfuReloadCompleted")
}

/// Window scene delegate installed via configurationForConnecting. SwiftUI owns
/// the window; this class only handles the events UIKit routes to the scene
/// delegate instead of the application delegate.
final class AppSceneDelegate: NSObject, UIWindowSceneDelegate {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// A quick action used to cold-launch the app arrives in the connection
    /// options; windowScene(_:performActionFor:) is not called for that launch.
    func scene(_: UIScene, willConnectTo _: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcutItem = connectionOptions.shortcutItem {
            handleShortcutItem(shortcutItem)
        }
    }

    /// Called when the user taps the "Speak BG" Home Screen quick action while
    /// the app is already running.
    func windowScene(_: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(handleShortcutItem(shortcutItem))
    }

    @discardableResult
    private func handleShortcutItem(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              shortcutItem.type == bundleIdentifier + ".toggleSpeakBG"
        else {
            return false
        }
        Storage.shared.speakBG.value.toggle()
        let message = Storage.shared.speakBG.value ? "BG Speak is now on" : "BG Speak is now off"
        speechSynthesizer.speak(AVSpeechUtterance(string: message))
        return true
    }

    /// With a custom scene delegate installed, UIKit delivers opened URLs here
    /// rather than through SwiftUI's onOpenURL, so the Live Activity tap
    /// handling from LoopFollowApp is mirrored. Posting twice is harmless —
    /// the navigation it triggers is idempotent.
    func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard URLContexts.contains(where: { $0.url.scheme == AppGroupID.urlScheme && $0.url.host == "la-tap" }) else { return }
        #if !targetEnvironment(macCatalyst)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .liveActivityDidForeground, object: nil)
            }
        #endif
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        let content = notification.request.content
        let userInfoKeys = content.userInfo.keys.compactMap { $0 as? String }.sorted()
        LogManager.shared.log(
            category: .general,
            message: "Will present notification: keys=\(userInfoKeys), interruption=\(content.interruptionLevel.rawValue), title=\(content.title.isEmpty ? "empty" : "set"), body=\(content.body.isEmpty ? "empty" : "set")"
        )

        // Suppress notifications iOS routes here that we never intended to surface:
        // the Live Activity push-to-start uses interruption-level: passive with empty
        // title/body and must not produce a banner or sound when LF is foregrounded.
        if content.interruptionLevel == .passive || (content.title.isEmpty && content.body.isEmpty) {
            completionHandler([])
            return
        }

        completionHandler([.banner, .sound, .badge])
    }
}
