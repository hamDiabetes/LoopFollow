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
///
/// The reading is not the only thing a tap is asking after. A loop that has
/// failed, or has just recovered, turns over between two CGM readings, and that
/// gap is exactly when the button gets pressed, so the loop's own state is
/// refreshed on its own account as well. The reading that comes back with it
/// does not move in that case, and neither does the age drawn over it.
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

        // A stored reading stamped ahead of this device cannot be ranked by age
        // at all, since the clock that wrote it is wrong, so it does not get to
        // hold off a reading that Nightscout is serving as the current one.
        let stored = GlucoseSnapshotStore.shared.load()
        let storedAt = stored?.updatedAt ?? .distantPast
        let storedIsRankable = storedAt <= Date().addingTimeInterval(60)
        let hasNewerReading = !storedIsRankable || reading.date > storedAt

        // Nothing to write when neither the reading nor the loop has moved on.
        // The stored snapshot is at least as recent and carries the fields this
        // cannot rebuild, so replacing it would only lose them.
        //
        // Nothing to write is still something to say, though: the reading and
        // its age are about to redraw as they were, and without the note the tap
        // is indistinguishable from one that did nothing at all.
        let refreshed: GlucoseSnapshot
        if hasNewerReading {
            refreshed = snapshot(reading: reading, status: status)
        } else if let stored, loopMoved(from: stored, to: status) {
            refreshed = snapshot(carrying: stored, status: status)
        } else {
            LAAppGroupSettings.setRefreshFailed(at: nil)
            LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: false)
            WidgetRefreshOutcome.set(movedLoop: false)
            return .result()
        }

        // Chart first. Should the process be stopped between the two writes, a
        // renewed chart beside the app's older snapshot is the state the widget
        // already lives in whenever its cache runs stale, and the age line still
        // describes the snapshot it is drawn from. The other order would put a
        // fresh age over an old chart.
        await save(entries.series)
        await save(refreshed)
        LAAppGroupSettings.setRefreshFailed(at: nil)
        LAAppGroupSettings.setRefreshChecked(at: Date(), broughtNewData: hasNewerReading)
        WidgetRefreshOutcome.set(movedLoop: !hasNewerReading)

        // WidgetKit reloads the timeline once this returns, so asking it to is
        // a second reload for the same change.
        return .result()
    }

    // MARK: - What moved

    /// Whether a write is owed on the loop's account alone.
    ///
    /// Two ways it can be. The site can be serving a record later than the one
    /// the stored snapshot was read from, which is a loop that has reported
    /// since. Or the record can be the same one, aged past the point where it
    /// still describes a running loop: a loop that stops does not report that it
    /// has stopped, so nothing newer is ever going to arrive and the fifteen
    /// minute verdict is the only thing that moves.
    ///
    /// Judged on the loop's own clock and on that verdict, never on the metrics.
    /// The app and this fetcher read several of the same numbers out of different
    /// keys and through different conversions, so one of them reading differently
    /// is no evidence that anything changed, and acting on it would throw away
    /// the app's fuller snapshot on every tap.
    private func loopMoved(from stored: GlucoseSnapshot, to status: NightscoutDeviceStatus) -> Bool {
        if status.isNotLooping != stored.isNotLooping { return true }
        // A snapshot written before the clock was recorded cannot be ranked, so
        // it is left alone until the app next writes one that can.
        guard let fetched = status.loopClock, let known = stored.loopUpdatedAt else { return false }
        return fetched > known
    }

    // MARK: - Assembly

    private func snapshot(reading: NightscoutReading, status: NightscoutDeviceStatus) -> GlucoseSnapshot {
        snapshot(
            glucose: reading.mgdl,
            delta: reading.deltaMgdl,
            trend: Self.trend(from: reading.direction),
            readAt: reading.date,
            status: status
        )
    }

    /// A loop only refresh. The reading, its delta and its trend are the stored
    /// ones untouched, and so is the timestamp the age line counts from, so that
    /// line goes on describing the same reading it described before the tap. The
    /// rest is rebuilt from the fetch on exactly the terms a full refresh uses,
    /// which is what keeps a field this cannot source from outliving the record
    /// it came from.
    private func snapshot(carrying stored: GlucoseSnapshot, status: NightscoutDeviceStatus) -> GlucoseSnapshot {
        snapshot(
            glucose: stored.glucose,
            delta: stored.delta,
            trend: stored.trend,
            readAt: stored.updatedAt,
            status: status
        )
    }

    /// One assembly for both paths, so the reading half and the loop half cannot
    /// drift apart in what they write.
    private func snapshot(
        glucose: Double,
        delta: Double,
        trend: GlucoseSnapshot.Trend,
        readAt: Date,
        status: NightscoutDeviceStatus
    ) -> GlucoseSnapshot {
        GlucoseSnapshot(
            glucose: glucose,
            delta: delta,
            trend: trend,
            updatedAt: readAt,
            loopUpdatedAt: status.loopClock,
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

/// Whether the last refresh that landed had only the loop to report. It sits
/// beside the intent because it never leaves the extension: this is the only
/// thing that writes it and the timeline provider is the only thing that reads
/// it, both of them in the same process.
///
/// Written on every path that marks a refresh as checked, so it can never be
/// read as the answer to an earlier tap than the one the timestamp names.
enum WidgetRefreshOutcome {
    private static let key = "la.widget.refreshMovedLoop"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.current())
    }

    static func set(movedLoop: Bool) {
        defaults?.set(movedLoop, forKey: key)
    }

    static func movedLoop() -> Bool {
        defaults?.bool(forKey: key) ?? false
    }
}
