// LoopFollow
// LAAppGroupSettings.swift

import Foundation

// MARK: - Slot option enum

/// One displayable metric that can occupy a slot in the Live Activity 2×2 grid.
///
/// - `.none` is the empty/blank state — leaves the slot visually empty.
/// - Optional cases (isOptional == true) may display "—" for Dexcom-only users
///   whose setup does not provide that metric.
/// - All values are read from GlucoseSnapshot at render time inside the widget
///   extension; no additional App Group reads are required per slot.
enum LiveActivitySlotOption: String, CaseIterable, Codable {
    // Core glucose
    case none
    case delta
    case projectedBG
    case minMax
    // Loop metrics
    case iob
    case cob
    case recBolus
    case autosens
    case tdd
    // Pump / device
    case basal
    case pump
    case pumpBattery
    case battery
    case target
    case isf
    case carbRatio
    // Ages
    case sage
    case cage
    case iage
    // Other
    case carbsToday
    case override
    case profile

    /// Human-readable label shown in the slot picker in Settings.
    var displayName: String {
        switch self {
        case .none: "Empty"
        case .delta: "Delta"
        case .projectedBG: "Projected BG"
        case .minMax: "Min/Max"
        case .iob: "IOB"
        case .cob: "COB"
        case .recBolus: "Rec. Bolus"
        case .autosens: "Autosens"
        case .tdd: "TDD"
        case .basal: "Basal"
        case .pump: "Pump"
        case .pumpBattery: "Pump Battery"
        case .battery: "Battery"
        case .target: "Target"
        case .isf: "ISF"
        case .carbRatio: "CR"
        case .sage: "SAGE"
        case .cage: "CAGE"
        case .iage: "IAGE"
        case .carbsToday: "Carbs today"
        case .override: "Override"
        case .profile: "Profile"
        }
    }

    /// Short label used inside the MetricBlock on the Live Activity card.
    var gridLabel: String {
        switch self {
        case .none: ""
        case .delta: "Delta"
        case .projectedBG: "Proj"
        case .minMax: "Min/Max"
        case .iob: "IOB"
        case .cob: "COB"
        case .recBolus: "Rec."
        case .autosens: "Sens"
        case .tdd: "TDD"
        case .basal: "Basal"
        case .pump: "Pump"
        case .pumpBattery: "Pump%"
        case .battery: "Bat."
        case .target: "Target"
        case .isf: "ISF"
        case .carbRatio: "CR"
        case .sage: "SAGE"
        case .cage: "CAGE"
        case .iage: "IAGE"
        case .carbsToday: "Carbs"
        case .override: "Ovrd"
        case .profile: "Prof"
        }
    }

    /// True when the value is a glucose measurement and should be followed by
    /// the user's preferred unit label (mg/dL or mmol/L) in compact displays.
    var isGlucoseUnit: Bool {
        switch self {
        case .projectedBG, .delta, .minMax, .target, .isf: return true
        default: return false
        }
    }

    /// Options selectable for the lock-screen 2×2 grid. The active override is
    /// excluded — the card has a dedicated override/temp-target countdown row.
    /// It remains selectable for the single CarPlay/Watch slot, which has no
    /// such row.
    static var gridCases: [LiveActivitySlotOption] {
        allCases.filter { $0 != .override }
    }

    /// True when the underlying value may be nil (e.g. Dexcom-only users who have
    /// no Loop data). The widget renders "—" in those cases.
    var isOptional: Bool {
        switch self {
        case .none, .delta: false
        default: true
        }
    }
}

// MARK: - Default slot assignments

enum LiveActivitySlotDefaults {
    /// Top-left slot
    static let slot1: LiveActivitySlotOption = .iob
    /// Bottom-left slot
    static let slot2: LiveActivitySlotOption = .cob
    /// Top-right slot
    static let slot3: LiveActivitySlotOption = .projectedBG
    /// Bottom-right slot — intentionally empty until the user configures it
    static let slot4: LiveActivitySlotOption = .none
    /// Small widget (CarPlay / Watch Smart Stack) right slot
    static let smallWidgetSlot: LiveActivitySlotOption = .projectedBG

    static var all: [LiveActivitySlotOption] {
        [slot1, slot2, slot3, slot4]
    }

    /// The home screen widget shows three: the fourth place along its base is
    /// the refresh button.
    static var widget: [LiveActivitySlotOption] {
        [slot1, slot2, slot3]
    }
}

// MARK: - Widget chart duration

/// Span of glucose history drawn on the home screen widget chart, chosen from
/// the widget's own Edit Widget sheet.
///
/// `GlucoseChartSeriesStore.window` has to cover the longest case here, or the
/// longer spans would draw the same readings as the shorter ones.
enum WidgetChartDuration: String, CaseIterable, Codable {
    case oneHour
    case threeHours
    case sixHours
    case twelveHours
    case twentyFourHours

    /// What the widget draws until the user picks something else. The
    /// @Parameter default in the configuration intent has to match.
    static let standard: WidgetChartDuration = .threeHours

    var seconds: TimeInterval {
        switch self {
        case .oneHour: 3600
        case .threeHours: 3 * 3600
        case .sixHours: 6 * 3600
        case .twelveHours: 12 * 3600
        case .twentyFourHours: 24 * 3600
        }
    }

    var displayName: String {
        switch self {
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        case .sixHours: "6 hours"
        case .twelveHours: "12 hours"
        case .twentyFourHours: "24 hours"
        }
    }
}

// MARK: - Widget chart style

/// How the home screen widget chart draws the readings, chosen from the
/// widget's own Edit Widget sheet.
enum WidgetChartStyle: String, CaseIterable, Codable {
    case dots
    case line
    case area

    /// What the widget draws until the user picks something else. The
    /// @Parameter default in the configuration intent has to match.
    static let standard: WidgetChartStyle = .dots

    var displayName: String {
        switch self {
        case .dots: "Dots"
        case .line: "Line"
        case .area: "Area"
        }
    }

    /// Whether the readings are joined into a trace rather than left as marks.
    var drawsLine: Bool {
        self != .dots
    }
}

// MARK: - Widget prediction horizon

/// How far forward the home screen widget draws the loop's forecast, chosen
/// from the widget's own Edit Widget sheet.
///
/// There is no longer option on purpose. A forecast is model output rather than
/// a measurement, and an hour of it is already a great deal to put on a surface
/// that is glanced at. What gets drawn is often shorter still: the loop
/// publishes curves of differing lengths and the envelope ends at the shortest
/// of them, so this is a ceiling and never a promise.
enum WidgetPredictionHorizon: String, CaseIterable, Codable {
    case never
    case fifteenMinutes
    case thirtyMinutes
    case sixtyMinutes

    /// Nothing is forecast until it is asked for. The @Parameter default in the
    /// configuration intent has to match.
    static let standard: WidgetPredictionHorizon = .never

    var seconds: TimeInterval {
        switch self {
        case .never: 0
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .sixtyMinutes: 60 * 60
        }
    }

    var displayName: String {
        switch self {
        case .never: "Never"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        case .sixtyMinutes: "60 min"
        }
    }
}

// MARK: - App Group settings

/// Minimal App Group settings needed by the Live Activity UI.
///
/// We keep this separate from Storage.shared to avoid target-coupling and
/// ensure the widget extension reads the same values as the app.
enum LAAppGroupSettings {
    private enum Keys {
        static let lowLineMgdl = "la.lowLine.mgdl"
        static let highLineMgdl = "la.highLine.mgdl"
        static let slots = "la.slots"
        static let smallWidgetSlot = "la.smallWidgetSlot"
        static let displayName = "la.displayName"
        static let showDisplayName = "la.showDisplayName"
        static let nightscoutURL = "la.nightscout.url"
        static let nightscoutToken = "la.nightscout.token"
        static let preferredUnit = "la.preferredUnit"
        static let refreshFailedAt = "la.widget.refreshFailedAt"
        static let refreshCheckedAt = "la.widget.refreshCheckedAt"
        static let refreshBroughtNewData = "la.widget.refreshBroughtNewData"
        static let relayEnabled = "la.relay.enabled"
        static let relayURL = "la.relay.url"
        static let relaySecret = "la.relay.secret"
        static let relayDeviceId = "la.relay.deviceId"
        static let relayBundleId = "la.relay.bundleId"
        static let relayEnvironment = "la.relay.environment"
        static let relayDeviceName = "la.relay.deviceName"
        static let relayWidgetTokenAt = "la.relay.widgetTokenAt"
        static let relayWidgetTokenTail = "la.relay.widgetTokenTail"
        static let relayWidgetTokenError = "la.relay.widgetTokenError"
        static let relayWidgetPushReloadAt = "la.relay.widgetPushReloadAt"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.current())
    }

    // MARK: - Thresholds (Write)

    static func setThresholds(lowMgdl: Double, highMgdl: Double) {
        defaults?.set(lowMgdl, forKey: Keys.lowLineMgdl)
        defaults?.set(highMgdl, forKey: Keys.highLineMgdl)
    }

    // MARK: - Thresholds (Read)

    static func thresholdsMgdl(fallbackLow: Double = 70, fallbackHigh: Double = 180) -> (low: Double, high: Double) {
        let low = defaults?.object(forKey: Keys.lowLineMgdl) as? Double ?? fallbackLow
        let high = defaults?.object(forKey: Keys.highLineMgdl) as? Double ?? fallbackHigh
        return (low, high)
    }

    // MARK: - Slot configuration (Write)

    /// Persists a 4-slot configuration to the App Group container.
    /// - Parameter slots: Array of exactly 4 `LiveActivitySlotOption` values;
    ///   extra elements are ignored, missing elements are filled with `.none`.
    static func setSlots(_ slots: [LiveActivitySlotOption]) {
        let raw = slots.prefix(4).map(\.rawValue)
        defaults?.set(raw, forKey: Keys.slots)
    }

    // MARK: - Slot configuration (Read)

    /// Returns the current 4-slot configuration, falling back to defaults
    /// if no configuration has been saved yet.
    static func slots() -> [LiveActivitySlotOption] {
        guard let raw = defaults?.stringArray(forKey: Keys.slots), raw.count == 4 else {
            return LiveActivitySlotDefaults.all
        }
        // .override is no longer a grid option (the card has a dedicated
        // override/temp-target row); selections stored by older versions
        // render as empty cells.
        return raw.map { LiveActivitySlotOption(rawValue: $0) ?? .none }
            .map { $0 == .override ? .none : $0 }
    }

    // MARK: - Small widget slot (Write)

    static func setSmallWidgetSlot(_ slot: LiveActivitySlotOption) {
        defaults?.set(slot.rawValue, forKey: Keys.smallWidgetSlot)
    }

    // MARK: - Small widget slot (Read)

    static func smallWidgetSlot() -> LiveActivitySlotOption {
        guard let raw = defaults?.string(forKey: Keys.smallWidgetSlot) else {
            return LiveActivitySlotDefaults.smallWidgetSlot
        }
        return LiveActivitySlotOption(rawValue: raw) ?? LiveActivitySlotDefaults.smallWidgetSlot
    }

    // MARK: - Display Name

    static func setDisplayName(_ name: String, show: Bool) {
        defaults?.set(name, forKey: Keys.displayName)
        defaults?.set(show, forKey: Keys.showDisplayName)
    }

    static func displayName() -> String {
        defaults?.string(forKey: Keys.displayName) ?? "LoopFollow"
    }

    static func showDisplayName() -> Bool {
        defaults?.bool(forKey: Keys.showDisplayName) ?? false
    }

    // MARK: - Nightscout connection

    /// Mirrors the site the app polls so an extension can fetch on its own when
    /// its cached data has gone stale. An empty url means "not configured".
    static func setNightscout(url: String, token: String) {
        defaults?.set(url, forKey: Keys.nightscoutURL)
        defaults?.set(token, forKey: Keys.nightscoutToken)
    }

    static func nightscoutURL() -> String {
        defaults?.string(forKey: Keys.nightscoutURL) ?? ""
    }

    static func nightscoutToken() -> String {
        defaults?.string(forKey: Keys.nightscoutToken) ?? ""
    }

    // MARK: - Preferred glucose unit

    /// Mirrors the app's unit selection so a surface that has a chart but no
    /// snapshot still labels and scales it in the unit the user reads in.
    static func setPreferredUnit(_ unit: GlucoseSnapshot.Unit) {
        defaults?.set(unit.rawValue, forKey: Keys.preferredUnit)
    }

    static func preferredUnit() -> GlucoseSnapshot.Unit {
        guard let raw = defaults?.string(forKey: Keys.preferredUnit) else { return .mgdl }
        return GlucoseSnapshot.Unit(rawValue: raw) ?? .mgdl
    }

    // MARK: - Widget refresh

    /// When the widget's own refresh last failed to reach Nightscout, so the
    /// render that follows can say the tap did not land. Nil clears it, which is
    /// what a refresh that did land writes.
    static func setRefreshFailed(at date: Date?) {
        guard let date else {
            defaults?.removeObject(forKey: Keys.refreshFailedAt)
            return
        }
        defaults?.set(date.timeIntervalSince1970, forKey: Keys.refreshFailedAt)
    }

    static func refreshFailedAt() -> Date? {
        guard let seconds = defaults?.object(forKey: Keys.refreshFailedAt) as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// When the refresh last reached Nightscout, and whether the site answered
    /// with a reading newer than the stored one. A tap that finds nothing newer
    /// has still done its work, and the render after it is the only chance to
    /// say so: nothing can be drawn while the intent is running.
    static func setRefreshChecked(at date: Date, broughtNewData: Bool) {
        defaults?.set(date.timeIntervalSince1970, forKey: Keys.refreshCheckedAt)
        defaults?.set(broughtNewData, forKey: Keys.refreshBroughtNewData)
    }

    static func clearRefreshChecked() {
        defaults?.removeObject(forKey: Keys.refreshCheckedAt)
        defaults?.removeObject(forKey: Keys.refreshBroughtNewData)
    }

    static func refreshCheckedAt() -> Date? {
        guard let seconds = defaults?.object(forKey: Keys.refreshCheckedAt) as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func refreshBroughtNewData() -> Bool {
        defaults?.bool(forKey: Keys.refreshBroughtNewData) ?? false
    }

    // MARK: - Relay registration

    /// Mirrors everything an extension needs to register a push token with the
    /// relay on its own.
    ///
    /// The widget's push token is delivered to the widget extension, not to the
    /// app, and the extension can be run at a moment when the app has not been
    /// alive for hours — which is the situation the relay exists to survive. So
    /// the extension cannot ask the app for any of this and has to find it here.
    ///
    /// `deviceId`, `bundleId` and `name` are mirrored rather than recomputed
    /// because an extension does not necessarily resolve them to the same values
    /// the app does: `Bundle.main` is the extension's own, and a registration
    /// under a different device ID would appear to the relay as a second phone.
    static func setRelay(
        enabled: Bool,
        url: String,
        secret: String,
        deviceId: String,
        bundleId: String,
        environment: String,
        deviceName: String
    ) {
        defaults?.set(enabled, forKey: Keys.relayEnabled)
        defaults?.set(url, forKey: Keys.relayURL)
        defaults?.set(secret, forKey: Keys.relaySecret)
        defaults?.set(deviceId, forKey: Keys.relayDeviceId)
        defaults?.set(bundleId, forKey: Keys.relayBundleId)
        defaults?.set(environment, forKey: Keys.relayEnvironment)
        defaults?.set(deviceName, forKey: Keys.relayDeviceName)
    }

    static func relayEnabled() -> Bool {
        defaults?.bool(forKey: Keys.relayEnabled) ?? false
    }

    static func relayURL() -> String {
        defaults?.string(forKey: Keys.relayURL) ?? ""
    }

    static func relaySecret() -> String {
        defaults?.string(forKey: Keys.relaySecret) ?? ""
    }

    static func relayDeviceId() -> String {
        defaults?.string(forKey: Keys.relayDeviceId) ?? ""
    }

    static func relayBundleId() -> String {
        defaults?.string(forKey: Keys.relayBundleId) ?? ""
    }

    static func relayEnvironment() -> String {
        defaults?.string(forKey: Keys.relayEnvironment) ?? "sandbox"
    }

    static func relayDeviceName() -> String {
        defaults?.string(forKey: Keys.relayDeviceName) ?? ""
    }

    // MARK: - Widget push diagnostics

    /// The last attempt to hand the widget's push token to the relay.
    ///
    /// The extension has no LogManager, and a token that never reaches the relay
    /// is a widget that quietly stops refreshing — the exact shape of failure
    /// this project keeps running into. Recording the attempt here is what lets
    /// the settings screen say whether iOS has issued a token at all.
    static func setWidgetTokenAttempt(at date: Date, tokenTail: String, error: String?) {
        defaults?.set(date.timeIntervalSince1970, forKey: Keys.relayWidgetTokenAt)
        defaults?.set(tokenTail, forKey: Keys.relayWidgetTokenTail)
        defaults?.set(error ?? "", forKey: Keys.relayWidgetTokenError)
    }

    static func widgetTokenAttemptAt() -> Date? {
        guard let seconds = defaults?.object(forKey: Keys.relayWidgetTokenAt) as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func widgetTokenTail() -> String {
        defaults?.string(forKey: Keys.relayWidgetTokenTail) ?? ""
    }

    static func widgetTokenError() -> String {
        defaults?.string(forKey: Keys.relayWidgetTokenError) ?? ""
    }

    /// When a timeline reload last ran. WidgetKit pushes are budgeted and
    /// delivered opportunistically, so APNs accepting one says nothing about
    /// whether the widget redrew; this is the only end of that trip we can see.
    static func setWidgetReload(at date: Date) {
        defaults?.set(date.timeIntervalSince1970, forKey: Keys.relayWidgetPushReloadAt)
    }

    static func widgetReloadAt() -> Date? {
        guard let seconds = defaults?.object(forKey: Keys.relayWidgetPushReloadAt) as? Double, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// Explicit so the widget can use this enum as an AppEnum parameter; the
// implicit conformance would land outside this file.
extension LiveActivitySlotOption: Sendable {}
extension WidgetChartDuration: Sendable {}
extension WidgetPredictionHorizon: Sendable {}
