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
/// What that costs, against what the app itself can show: basal, override, carbs
/// today, the sensor, cannula and insulin ages and the profile name come from
/// treatments and the profile, which are several more requests than a reload can
/// wait for. Everything the loop posts to devicestatus survives.
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

        let entries = await entriesTask
        let status = await statusTask

        guard let entries, let reading = entries.reading, let status else { return .unreachable }

        let storedIsRankable = stored <= Date().addingTimeInterval(clockSkewAllowance)
        guard !storedIsRankable || reading.date > stored else { return .nothingNewer }

        return .refreshed(
            Payload(
                series: entries.series,
                snapshot: snapshot(reading: reading, status: status),
                prediction: prediction(status: status, reading: reading)
            )
        )
    }

    // MARK: - Assembly

    static func snapshot(reading: NightscoutReading, status: NightscoutDeviceStatus) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: reading.mgdl,
            delta: reading.deltaMgdl,
            trend: trend(from: reading.direction),
            updatedAt: reading.date,
            iob: status.iob,
            cob: status.cob,
            projected: status.projected,
            override: nil,
            recBolus: status.recBolus,
            battery: status.battery,
            pumpBattery: status.pumpBattery,
            basalRate: "",
            pumpReservoirU: status.pumpReservoirU,
            pumpReservoirAboveMax: status.pumpReservoirAboveMax,
            autosens: status.autosens,
            tdd: status.tdd,
            targetLowMgdl: status.targetLowMgdl,
            targetHighMgdl: status.targetHighMgdl,
            isfMgdlPerU: status.isfMgdlPerU,
            carbRatio: status.carbRatio,
            carbsToday: nil,
            profileName: nil,
            sageInsertTime: 0,
            cageInsertTime: 0,
            iageInsertTime: 0,
            minBgMgdl: status.minBgMgdl,
            maxBgMgdl: status.maxBgMgdl,
            unit: LAAppGroupSettings.preferredUnit(),
            isNotLooping: status.isNotLooping
        )
    }

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
