// LoopFollow
// RefreshWidgetIntent.swift

import AppIntents

/// The widget's own refresh, run when the button along the base is tapped.
///
/// This runs inside the widget extension, where none of the app's parsing is
/// reachable, so everything it writes is rebuilt out of the two Nightscout
/// responses it fetches here. The snapshot is rebuilt whole rather than patched:
/// the widget puts a single age over the reading and the metrics beside it, so a
/// field this cannot source is written empty and reads as unavailable. Carrying
/// the app's older value forward would restate it under a timestamp it has not
/// got, and the metrics would be older than the age line claims.
///
/// What that costs, against what the app itself can show: basal, override, carbs
/// today, the sensor, cannula and insulin ages and the profile name come from
/// treatments and the profile, which are several more requests than a tap can
/// wait for, so those blocks fall back to their no value glyph until the app
/// next writes. Everything the loop posts to devicestatus survives the refresh.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Glucose"
    static var description = IntentDescription("Reads the latest glucose and loop status from Nightscout.")

    /// Reached only from the widget's own button, and it needs the widget's
    /// process to write the App Group, so it neither opens the app nor offers
    /// itself as a shortcut.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        let url = LAAppGroupSettings.nightscoutURL()
        // The button is not drawn without a site to ask, so this is the case
        // where one was removed between the render and the tap.
        guard !url.isEmpty else { return .result() }
        let token = LAAppGroupSettings.nightscoutToken()

        async let entriesTask = NightscoutChartFetcher.fetch(baseURL: url, token: token)
        async let statusTask = NightscoutDeviceStatusFetcher.fetch(baseURL: url, token: token)

        let entries = await entriesTask
        let status = await statusTask

        guard let entries, let reading = entries.reading, let status else {
            LAAppGroupSettings.setRefreshFailed(at: Date())
            LAAppGroupSettings.clearRefreshChecked()
            return .result()
        }

        // Nothing to write when the site has not got a newer reading than the
        // app already stored. The stored one is at least as recent and carries
        // the fields this cannot rebuild, so replacing it would only lose them.
        //
        // A stored reading stamped ahead of this device cannot be ranked by age
        // at all, since the clock that wrote it is wrong, so it does not get to
        // hold off a reading that Nightscout is serving as the current one.
        //
        // Nothing to write is still something to say, though: the reading and
        // its age are about to redraw as they were, and without the note the tap
        // is indistinguishable from one that did nothing at all.
        let stored = GlucoseSnapshotStore.shared.load()?.updatedAt ?? .distantPast
        let storedIsRankable = stored <= Date().addingTimeInterval(60)
        guard !storedIsRankable || reading.date > stored else {
            LAAppGroupSettings.setRefreshFailed(at: nil)
            LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: false)
            return .result()
        }

        // Chart first. Should the process be stopped between the two writes, a
        // renewed chart beside the app's older snapshot is the state the widget
        // already lives in whenever its cache runs stale, and the age line still
        // describes the snapshot it is drawn from. The other order would put a
        // fresh age over an old chart.
        await save(entries.series)
        await save(snapshot(reading: reading, status: status))
        LAAppGroupSettings.setRefreshFailed(at: nil)
        LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: true)

        // WidgetKit reloads the timeline once this returns, so asking it to is
        // a second reload for the same change.
        return .result()
    }

    // MARK: - Assembly

    private func snapshot(reading: NightscoutReading, status: NightscoutDeviceStatus) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: reading.mgdl,
            delta: reading.deltaMgdl,
            trend: Self.trend(from: reading.direction),
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

    /// Nightscout's own spelling of the trend, matched the way the app's snapshot
    /// builder matches it so the arrow does not change meaning between them.
    private static func trend(from direction: String?) -> GlucoseSnapshot.Trend {
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

    // MARK: - Storage

    /// Both stores write on their own queue, and the widget is redrawn the moment
    /// this returns, so a fire and forget save would race the render.
    private func save(_ series: GlucoseChartSeries) async {
        await withCheckedContinuation { continuation in
            GlucoseChartSeriesStore.shared.save(series) { continuation.resume() }
        }
    }

    private func save(_ snapshot: GlucoseSnapshot) async {
        await withCheckedContinuation { continuation in
            GlucoseSnapshotStore.shared.save(snapshot) { continuation.resume() }
        }
    }
}
