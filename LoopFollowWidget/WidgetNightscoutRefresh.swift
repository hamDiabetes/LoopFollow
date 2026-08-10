// LoopFollow
// WidgetNightscoutRefresh.swift

import Foundation

/// Rebuilds what the widget draws straight from Nightscout, for the paths that
/// run while the app is asleep.
///
/// The App Group caches are written by the app, so they stop advancing the
/// moment iOS suspends it — which is most of the time. Both of the widget's own
/// ways of getting current again, the refresh button and a timeline run woken by
/// the relay, need the same two responses assembled the same way, so the
/// assembly lives here rather than twice.
///
/// The snapshot is rebuilt whole rather than patched. The widget puts a single
/// age over the reading and the metrics beside it, so a field this cannot source
/// is written empty and reads as unavailable; carrying the app's older value
/// forward would restate it under a timestamp it has not got.
///
/// Every field the app can show is sourced here: the reading and its history
/// from entries, the loop's own numbers from devicestatus, and basal, override,
/// temporary target, carbs today, the sensor, cannula and insulin ages and the
/// profile name from treatments and the profile. They are asked for as separate
/// narrow questions rather than as one window of everything — see
/// `NightscoutTreatmentsFetcher` for why that matters inside an extension.
///
/// A field still ends up empty when the request behind it did not land. That is
/// a different thing from a value known to be absent, but it is the same thing
/// on screen, and it is the honest one: what it never says is that a number
/// gathered at some earlier time describes the moment this timestamp claims.
enum WidgetNightscoutRefresh {
    /// A stored reading stamped ahead of this device cannot be ranked by age at
    /// all, since the clock that wrote it is wrong, so past this much skew it
    /// does not get to hold off a reading Nightscout is serving as the current
    /// one.
    private static let clockSkewAllowance: TimeInterval = 60

    struct Payload {
        let series: GlucoseChartSeries
        let snapshot: GlucoseSnapshot
        /// Nil when the record carried no forecast, which is a forecast to take
        /// off the widget rather than an absence to ignore.
        let prediction: GlucosePrediction?
    }

    enum Outcome {
        case refreshed(Payload)

        /// The site answered and has nothing newer than what is already stored.
        /// The stored copy is at least as recent and carries the fields this
        /// cannot rebuild, so replacing it would only lose them.
        case nothingNewer

        /// No site configured, the request did not land, or it landed with
        /// nothing plottable. Distinct from `nothingNewer` because one of them
        /// means the data is current and the other means it is unknown.
        case unreachable
    }

    /// Fetch and assemble, keeping the result only if it beats `stored`.
    ///
    /// Both requests go out together: they are independent, and a reload is
    /// waiting on the pair rather than on either.
    static func fetch(newerThan stored: Date) async -> Outcome {
        let url = LAAppGroupSettings.nightscoutURL()
        guard !url.isEmpty else { return .unreachable }
        let token = LAAppGroupSettings.nightscoutToken()

        async let entriesTask = NightscoutChartFetcher.fetch(baseURL: url, token: token)
        async let statusTask = NightscoutDeviceStatusFetcher.fetch(baseURL: url, token: token)
        async let treatmentsTask = NightscoutTreatmentsFetcher.fetch(baseURL: url, token: token)

        let entries = await entriesTask
        let status = await statusTask
        let treatments = await treatmentsTask

        guard let entries, let reading = entries.reading, let status else { return .unreachable }

        let storedIsRankable = stored <= Date().addingTimeInterval(clockSkewAllowance)
        guard !storedIsRankable || reading.date > stored else { return .nothingNewer }

        return .refreshed(
            Payload(
                series: entries.series,
                snapshot: snapshot(reading: reading, status: status, treatments: treatments),
                prediction: prediction(status: status, reading: reading)
            )
        )
    }

    // MARK: - Assembly

    static func snapshot(
        reading: NightscoutReading,
        status: NightscoutDeviceStatus,
        treatments: NightscoutTreatmentState?
    ) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: reading.mgdl,
            delta: reading.deltaMgdl,
            trend: trend(from: reading.direction),
            updatedAt: reading.date,
            iob: status.iob,
            cob: status.cob,
            projected: status.projected,
            override: treatments?.override,
            overrideEndAt: treatments?.overrideEndAt,
            tempTargetMgdl: treatments?.tempTargetMgdl,
            tempTargetEndAt: treatments?.tempTargetEndAt,
            recBolus: status.recBolus,
            battery: status.battery,
            pumpBattery: status.pumpBattery,
            basalRate: basalRate(status: status, treatments: treatments),
            pumpReservoirU: status.pumpReservoirU,
            pumpReservoirAboveMax: status.pumpReservoirAboveMax,
            autosens: status.autosens,
            tdd: status.tdd,
            // The loop states the target it is working to, which is the one in
            // force including any temporary override of it. The profile's is the
            // schedule underneath that, so it is only the fallback.
            targetLowMgdl: status.targetLowMgdl ?? treatments?.targetLowMgdl,
            targetHighMgdl: status.targetHighMgdl ?? treatments?.targetHighMgdl,
            isfMgdlPerU: status.isfMgdlPerU,
            carbRatio: status.carbRatio,
            carbsToday: treatments?.carbsToday,
            profileName: treatments?.profileName,
            sageInsertTime: treatments?.sageInsertTime ?? 0,
            cageInsertTime: treatments?.cageInsertTime ?? 0,
            iageInsertTime: treatments?.iageInsertTime ?? 0,
            minBgMgdl: status.minBgMgdl,
            maxBgMgdl: status.maxBgMgdl,
            unit: LAAppGroupSettings.preferredUnit(),
            isNotLooping: status.isNotLooping
        )
    }

    /// A running temp basal wins; without one the profile's schedule is what the
    /// pump is delivering. The loop reports a rate only while it is overriding
    /// the schedule, so falling through to the schedule is the difference
    /// between an empty slot and the rate actually going in.
    static func basalRate(status: NightscoutDeviceStatus, treatments: NightscoutTreatmentState?) -> String {
        guard let rate = status.tempBasalRate ?? treatments?.scheduledBasal else { return "" }
        return basalFormatter.string(from: NSNumber(value: rate)) ?? ""
    }

    /// Two fraction digits at most and none required, which is how the app
    /// writes the same string and how the relay puts it in the Live Activity.
    /// The unit is added by the display layer rather than baked in here.
    private static let basalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    /// Anchored to the loop's own clock, since that is the cycle the curves run
    /// forward from. Without one the reading is the closest thing to it.
    static func prediction(status: NightscoutDeviceStatus, reading: NightscoutReading) -> GlucosePrediction? {
        guard !status.predictionCurves.isEmpty else { return nil }
        return GlucosePrediction(
            curves: status.predictionCurves,
            source: status.predictionSource,
            anchor: status.loopClock ?? reading.date,
            updatedAt: Date()
        )
    }

    /// Nightscout's own spelling of the trend, matched the way the app's snapshot
    /// builder matches it so the arrow does not change meaning between them.
    static func trend(from direction: String?) -> GlucoseSnapshot.Trend {
        guard let direction = direction?.lowercased() else { return .unknown }
        switch direction {
        case "doubleup", "rapidrise", "up2", "upfast": return .upFast
        case "fortyfiveup": return .upSlight
        case "singleup", "up", "up1", "rising": return .up
        case "flat", "steady", "none": return .flat
        case "doubledown", "rapidfall", "down2", "downfast": return .downFast
        case "fortyfivedown": return .downSlight
        case "singledown", "down", "down1", "falling": return .down
        default: return .unknown
        }
    }
}
