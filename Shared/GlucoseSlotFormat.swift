// LoopFollow
// GlucoseSlotFormat.swift

import Foundation

/// Renders `GlucoseSnapshot` values as the strings shown in the Live Activity
/// and the home screen widget. Both surfaces format identically, so a value
/// reads the same wherever it appears.
enum LAFormat {
    private static let mgdlFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = 0
        nf.locale = .current
        return nf
    }()

    private static let mmolFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 1
        nf.maximumFractionDigits = 1
        nf.locale = .current
        return nf
    }()

    private static func formatGlucoseValue(_ mgdl: Double, unit: GlucoseSnapshot.Unit) -> String {
        switch unit {
        case .mgdl:
            return mgdlFormatter.string(from: NSNumber(value: round(mgdl))) ?? "\(Int(round(mgdl)))"
        case .mmol:
            let mmol = GlucoseConversion.toMmol(mgdl)
            return mmolFormatter.string(from: NSNumber(value: mmol)) ?? String(format: "%.1f", mmol)
        }
    }

    static func glucose(_ s: GlucoseSnapshot) -> String {
        formatGlucoseValue(s.glucose, unit: s.unit)
    }

    static func delta(_ s: GlucoseSnapshot) -> String {
        switch s.unit {
        case .mgdl:
            let v = Int(round(s.delta))
            if v == 0 { return "0" }
            return v > 0 ? "+\(v)" : "\(v)"
        case .mmol:
            let mmol = GlucoseConversion.toMmol(s.delta)
            let d = (abs(mmol) < 0.05) ? 0.0 : mmol
            if d == 0 { return mmolFormatter.string(from: 0) ?? "0.0" }
            let formatted = mmolFormatter.string(from: NSNumber(value: abs(d))) ?? String(format: "%.1f", abs(d))
            return d > 0 ? "+\(formatted)" : "-\(formatted)"
        }
    }

    static func trendArrow(_ s: GlucoseSnapshot) -> String {
        switch s.trend {
        case .upFast: "↑↑"
        case .up: "↑"
        case .upSlight: "↗"
        case .flat: "→"
        case .downSlight: "↘︎"
        case .down: "↓"
        case .downFast: "↓↓"
        case .unknown: "–"
        }
    }

    static func iob(_ s: GlucoseSnapshot) -> String {
        guard let v = s.iob else { return "—" }
        return String(format: "%.1f", v)
    }

    static func cob(_ s: GlucoseSnapshot) -> String {
        guard let v = s.cob else { return "—" }
        return String(Int(round(v)))
    }

    static func projected(_ s: GlucoseSnapshot) -> String {
        guard let v = s.projected else { return "—" }
        return formatGlucoseValue(v, unit: s.unit)
    }

    private static let ageFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .positional
        f.allowedUnits = [.day, .hour]
        f.zeroFormattingBehavior = [.pad]
        return f
    }()

    static func age(insertTime: TimeInterval) -> String {
        guard insertTime > 0 else { return "—" }
        let secondsAgo = Date().timeIntervalSince1970 - insertTime
        return ageFormatter.string(from: secondsAgo) ?? "—"
    }

    static func recBolus(_ s: GlucoseSnapshot) -> String {
        guard let v = s.recBolus else { return "—" }
        return String(format: "%.2fU", v)
    }

    static func autosens(_ s: GlucoseSnapshot) -> String {
        guard let v = s.autosens else { return "—" }
        return String(format: "%.0f%%", v * 100)
    }

    static func tdd(_ s: GlucoseSnapshot) -> String {
        guard let v = s.tdd else { return "—" }
        return String(format: "%.1fU", v)
    }

    static func basal(_ s: GlucoseSnapshot) -> String {
        s.basalRate.isEmpty ? "—" : s.basalRate
    }

    static func pump(_ s: GlucoseSnapshot) -> String {
        guard let v = s.pumpReservoirU else { return "50+U" }
        return "\(Int(round(v)))U"
    }

    static func pumpBattery(_ s: GlucoseSnapshot) -> String {
        guard let v = s.pumpBattery else { return "—" }
        return String(format: "%.0f%%", v)
    }

    static func battery(_ s: GlucoseSnapshot) -> String {
        guard let v = s.battery else { return "—" }
        return String(format: "%.0f%%", v)
    }

    static func target(_ s: GlucoseSnapshot) -> String {
        guard let low = s.targetLowMgdl, low > 0 else { return "—" }
        let lowStr = formatGlucoseValue(low, unit: s.unit)
        if let high = s.targetHighMgdl, high > 0, abs(high - low) > 0.5 {
            return "\(lowStr)-\(formatGlucoseValue(high, unit: s.unit))"
        }
        return lowStr
    }

    static func isf(_ s: GlucoseSnapshot) -> String {
        guard let v = s.isfMgdlPerU, v > 0 else { return "—" }
        return formatGlucoseValue(v, unit: s.unit)
    }

    static func carbRatio(_ s: GlucoseSnapshot) -> String {
        guard let v = s.carbRatio, v > 0 else { return "—" }
        return String(format: "%.0fg", v)
    }

    static func carbsToday(_ s: GlucoseSnapshot) -> String {
        guard let v = s.carbsToday else { return "—" }
        return "\(Int(round(v)))g"
    }

    static func minMax(_ s: GlucoseSnapshot) -> String {
        guard let mn = s.minBgMgdl, let mx = s.maxBgMgdl else { return "—" }
        return "\(formatGlucoseValue(mn, unit: s.unit))/\(formatGlucoseValue(mx, unit: s.unit))"
    }

    static func override(_ s: GlucoseSnapshot) -> String {
        s.override ?? "—"
    }

    static func tempTargetValue(_ s: GlucoseSnapshot) -> String? {
        guard let tt = s.tempTargetMgdl, tt > 0 else { return nil }
        return formatGlucoseValue(tt, unit: s.unit)
    }

    static func profileName(_ s: GlucoseSnapshot) -> String {
        s.profileName ?? "—"
    }

    /// A literal `dateFormat` would pin the clock to 24 hours whatever the device
    /// is set to, so the style is left for the locale to resolve.
    private static let hhmmFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.timeZone = .current
        df.dateStyle = .none
        df.timeStyle = .short
        return df
    }()

    private static let hhmmssFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = .current
        df.timeZone = .current
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    static func hhmmss(_ date: Date) -> String {
        hhmmssFormatter.string(from: date)
    }

    static func updated(_ s: GlucoseSnapshot) -> String {
        hhmmFormatter.string(from: s.updatedAt)
    }
}

func slotFormattedValue(option: LiveActivitySlotOption, snapshot: GlucoseSnapshot) -> String {
    switch option {
    case .none: ""
    case .delta: LAFormat.delta(snapshot)
    case .projectedBG: LAFormat.projected(snapshot)
    case .minMax: LAFormat.minMax(snapshot)
    case .iob: LAFormat.iob(snapshot)
    case .cob: LAFormat.cob(snapshot)
    case .recBolus: LAFormat.recBolus(snapshot)
    case .autosens: LAFormat.autosens(snapshot)
    case .tdd: LAFormat.tdd(snapshot)
    case .basal: LAFormat.basal(snapshot)
    case .pump: LAFormat.pump(snapshot)
    case .pumpBattery: LAFormat.pumpBattery(snapshot)
    case .battery: LAFormat.battery(snapshot)
    case .target: LAFormat.target(snapshot)
    case .isf: LAFormat.isf(snapshot)
    case .carbRatio: LAFormat.carbRatio(snapshot)
    case .sage: LAFormat.age(insertTime: snapshot.sageInsertTime)
    case .cage: LAFormat.age(insertTime: snapshot.cageInsertTime)
    case .iage: LAFormat.age(insertTime: snapshot.iageInsertTime)
    case .carbsToday: LAFormat.carbsToday(snapshot)
    case .override: LAFormat.override(snapshot)
    case .profile: LAFormat.profileName(snapshot)
    }
}
