// LoopFollow
// DeviceStatus.swift

import Foundation
import HealthKit
import SwiftUI
import WidgetKit

extension MainViewController {
    /// Publishes the loop's forecast to the App Group, for the home screen
    /// widget to draw as a cone. Called from both device shapes, so the two
    /// agree on what is published and when.
    ///
    /// Honours Download Prediction Data on both paths, so the widget's forecast
    /// follows the setting whichever device shape is in use.
    ///
    /// The in-app graph is left exactly as it was, and the two do not agree on
    /// the OpenAPS path: `updateOpenAPSPredictionDisplay` draws its cone without
    /// consulting the setting, so a Trio user who turns it off loses the widget's
    /// forecast but keeps the one on the chart. That predates this and is not
    /// changed here, because removing a cone people already see is a decision of
    /// its own.
    ///
    /// The curves are stored apart rather than as a finished envelope. They come
    /// at differing lengths, the widget decides how far forward to draw, and
    /// flattening here would take that choice away from it.
    func publishWidgetPrediction(curves: [String: [Double]]?, source: GlucosePredictionSource, anchor: TimeInterval?) {
        guard Storage.shared.downloadPrediction.value,
              let curves,
              let anchor,
              !curves.isEmpty
        else {
            guard GlucosePredictionStore.shared.load() != nil else { return }
            GlucosePredictionStore.shared.clear {
                WidgetCenter.shared.reloadTimelines(ofKind: MainViewController.widgetKind)
            }
            return
        }

        let minDisplay = Double(globalVariables.minDisplayGlucose)
        let maxDisplay = Double(globalVariables.maxDisplayGlucose)
        let clamped = curves.compactMapValues { curve -> [Double]? in
            let held = curve.prefix(GlucosePrediction.maxSamples).map { min(max($0, minDisplay), maxDisplay) }
            return held.isEmpty ? nil : held
        }
        guard !clamped.isEmpty else { return }

        let prediction = GlucosePrediction(
            curves: clamped,
            source: source,
            anchor: Date(timeIntervalSince1970: anchor),
            updatedAt: Date()
        )

        // The device status task reschedules every ten seconds while it is
        // failing, so an unconditional reload here would spend the widget's
        // refresh budget on forecasts that have not changed. `updatedAt` differs
        // on every write, so the comparison is on what is actually drawn.
        let stored = GlucosePredictionStore.shared.load()
        guard stored?.curves != prediction.curves || stored?.anchor != prediction.anchor else { return }

        GlucosePredictionStore.shared.save(prediction) {
            WidgetCenter.shared.reloadTimelines(ofKind: MainViewController.widgetKind)
        }
    }

    /// Retains the loop's carbs-on-board figure for the widget's purple ribbon.
    ///
    /// The app receives one of these on every poll and keeps only the newest, so
    /// the ribbon's series is kept here as it arrives rather than fetched back
    /// out of devicestatus history, which costs kilobytes a record for one
    /// integer apiece.
    ///
    /// `at` is the cycle's own timestamp rather than the moment of the fetch: a
    /// record can be uploaded well after the cycle it describes, and the ribbon
    /// has to sit where the carbs were counted.
    ///
    /// The widget is reloaded only when the store actually took a new sample.
    /// Both device shapes poll far more often than the loop publishes, and a
    /// reload per poll would spend the refresh budget restating the same figure.
    func publishWidgetCarbsOnBoard(grams: Double?, at cycle: TimeInterval?) {
        guard let grams, let cycle, cycle > 0 else { return }

        let sample = CarbsOnBoardSample(date: Date(timeIntervalSince1970: cycle), grams: grams)
        CarbsOnBoardStore.shared.append(sample) { changed in
            guard changed else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: MainViewController.widgetKind)
        }
    }

    /// Retains the loop's insulin-on-board figure, and the scale the ribbon is
    /// drawn against.
    ///
    /// The same cycle, one field over from carbs on board. `totalDailyDose` is
    /// what full ribbon height is a share of, so it travels with the series
    /// rather than living in a setting somebody has to keep current.
    func publishWidgetInsulinOnBoard(units: Double?, at cycle: TimeInterval?) {
        guard let units, let cycle, cycle > 0 else { return }

        let sample = InsulinOnBoardSample(date: Date(timeIntervalSince1970: cycle), units: units)
        InsulinOnBoardStore.shared.append(sample) { changed in
            guard changed else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: MainViewController.widgetKind)
        }
    }

    /// The most records one poll will accept.
    ///
    /// A day on this site is 527, at a median of four minutes apart. The cap is
    /// what stops a site that publishes far faster, or a clock that jumped,
    /// turning one poll into an unbounded download; a poll that reaches it
    /// simply covers less than the whole window and the next one continues.
    static let deviceStatusMaxRecords = 800

    /// How far back a poll reaches when nothing is held yet.
    ///
    /// The stores prune to this same window, so asking for more would only be
    /// parsed and then dropped on write.
    static var deviceStatusHistoryWindow: TimeInterval { CarbsOnBoardStore.window }

    /// Where the next poll starts: after the newest cycle already held, or a
    /// window back when the stores are empty.
    ///
    /// This is the whole of the fix for a ribbon drawn in scattered blocks. The
    /// poll asked for one record, so the series only ever held the cycles the
    /// app happened to be running for. Asking for everything since the newest
    /// held one costs a record in the steady state and fills the chart on the
    /// first poll after the app has been closed.
    ///
    /// One second past the newest held cycle, because the bound is inclusive and
    /// a record the app already has is a record it would pay to parse again.
    ///
    /// The bound is matched against `created_at` while the held date is the
    /// cycle's own stamp, and upload follows the cycle by a few seconds on this
    /// site. The two disagreeing in that direction re-reads a record; the other
    /// direction would skip one, so the cycle stamp is the safe one to bound on.
    static func deviceStatusSince(newestHeld: Date?, now: Date, window: TimeInterval) -> Date {
        let floor = now.addingTimeInterval(-window)
        guard let newestHeld, newestHeld > floor else { return floor }
        return newestHeld.addingTimeInterval(1)
    }

    func webLoadNSDeviceStatus() {
        // Off the main queue: the first poll of a session reads both stores to
        // find out how far back it has to reach.
        DispatchQueue.global(qos: .utility).async {
            let since = Self.deviceStatusSince(
                newestHeld: self.newestOnBoardCycle(),
                now: Date(),
                window: Self.deviceStatusHistoryWindow
            )
            let parameters = [
                "count": String(Self.deviceStatusMaxRecords),
                "find[created_at][$gte]": ISO8601DateFormatter().string(from: since),
            ]

            NightscoutUtils.executeDynamicRequest(eventType: .deviceStatus, parameters: parameters) { result in
                switch result {
                case let .success(json):
                    if let jsonDeviceStatus = json as? [[String: AnyObject]] {
                        DispatchQueue.main.async {
                            self.updateDeviceStatusDisplay(jsonDeviceStatus: jsonDeviceStatus)
                            self.retainOnBoardHistory(from: jsonDeviceStatus)
                            Storage.shared.lastLoopingChecked.value = Date()
                        }
                    } else {
                        self.handleDeviceStatusError()
                    }
                case .failure:
                    self.handleDeviceStatusError()
                }
            }
        }
    }

    /// The newest cycle either store holds, read once per launch.
    ///
    /// Cached because the alternative is two file reads on every poll, and
    /// because the answer only moves when this app moves it: the widget appends
    /// from behind, never ahead.
    ///
    /// The older of the two is taken. A poll that starts after the newer series
    /// would leave the other one short, and a few records fetched twice cost a
    /// parse where a missed cycle costs a hole in the ribbon.
    private func newestOnBoardCycle() -> Date? {
        if let known = onBoardCycleHighWater { return known }

        let carbs = CarbsOnBoardStore.shared.load()?.samples.last?.date
        let insulin = InsulinOnBoardStore.shared.load()?.samples.last?.date
        guard let oldest = [carbs, insulin].compactMap({ $0 }).min(), carbs != nil, insulin != nil else {
            // One series empty is a store that has to be filled from the window,
            // not one that can be caught up from where the other reached.
            return nil
        }

        onBoardCycleHighWater = oldest
        return oldest
    }

    /// Folds the window behind the newest record into the on-board series.
    ///
    /// The display reads `jsonDeviceStatus[0]` and the two publishers under it
    /// retain that cycle, so everything here is about the records behind it: the
    /// hours the app was not running. They go in as one write each rather than
    /// one per cycle.
    private func retainOnBoardHistory(from records: [[String: AnyObject]]) {
        guard records.count > 1 else { return }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]

        let onBoard = DeviceStatusHistory.onBoard(from: records, formatter: formatter)
        guard !onBoard.isEmpty else { return }

        if let newest = [onBoard.carbs.last?.date, onBoard.insulin.last?.date].compactMap({ $0 }).min() {
            onBoardCycleHighWater = newest
        }

        // One flag per writer. The two completions land on their own stores'
        // queues, and a single shared flag read-modify-written from both is a
        // race whose losing side is a backfill that draws nothing.
        let group = DispatchGroup()
        var carbsWrote = false
        var insulinWrote = false
        group.enter()
        CarbsOnBoardStore.shared.append(contentsOf: onBoard.carbs) { wrote in
            carbsWrote = wrote
            group.leave()
        }
        group.enter()
        InsulinOnBoardStore.shared.append(contentsOf: onBoard.insulin) { wrote in
            insulinWrote = wrote
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard carbsWrote || insulinWrote, let self else { return }
            // The read floor exists to keep rebuilds off the file system, and a
            // backfill is exactly the case it must not swallow.
            self.invalidateOnBoardHistories()
            self.refreshOnBoardHistories()
            WidgetCenter.shared.reloadTimelines(ofKind: MainViewController.widgetKind)
        }
    }

    private func handleDeviceStatusError() {
        LogManager.shared.log(category: .deviceStatus, message: "Device status fetch failed!", limitIdentifier: "Device status fetch failed!")
        DispatchQueue.main.async {
            Storage.shared.lastLoopingChecked.value = Date()
            TaskScheduler.shared.rescheduleTask(id: .deviceStatus, to: Date().addingTimeInterval(10))
            self.evaluateNotLooping()
        }
    }

    func evaluateNotLooping() {
        guard let lastLoopTime = Observable.shared.alertLastLoopTime.value, lastLoopTime > 0 else {
            return
        }

        let now = TimeInterval(Date().timeIntervalSince1970)
        let nonLoopingTimeThreshold: TimeInterval = 15 * 60

        if IsNightscoutEnabled(), (now - lastLoopTime) >= nonLoopingTimeThreshold, lastLoopTime > 0 {
            IsNotLooping = true
            Observable.shared.isNotLooping.value = true

            Observable.shared.loopStatusText.value = "⚠️ Not Looping!"
            Observable.shared.loopStatusColor.value = .yellow
            #if !targetEnvironment(macCatalyst)
                LiveActivityManager.shared.refreshFromCurrentState(reason: "notLooping")
            #endif

        } else {
            IsNotLooping = false
            Observable.shared.isNotLooping.value = false

            Observable.shared.loopStatusColor.value = .primary
            #if !targetEnvironment(macCatalyst)
                LiveActivityManager.shared.refreshFromCurrentState(reason: "loopingResumed")
            #endif
        }
    }

    // NS Device Status Response Processor
    func updateDeviceStatusDisplay(jsonDeviceStatus: [[String: AnyObject]]) {
        let previousIOBText = Observable.shared.iobText.value
        let previousDeviceWasLoop = Storage.shared.device.value == "Loop"
        infoManager.clearInfoData(types: [.iob, .cob, .battery, .pump, .pumpBattery, .target, .isf, .carbRatio, .updated, .recBolus, .tdd])

        // For Loop, clear the current override here - For Trio, it is handled using treatments
        if Storage.shared.device.value == "Loop" {
            infoManager.clearInfoData(types: [.override])
        }

        if jsonDeviceStatus.count == 0 {
            LogManager.shared.log(category: .deviceStatus, message: "Device status is empty")
            TaskScheduler.shared.rescheduleTask(id: .deviceStatus, to: Date().addingTimeInterval(5 * 60))
            return
        }

        // Process the current data first
        let lastDeviceStatus = jsonDeviceStatus[0] as [String: AnyObject]?

        // pump and uploader
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate,
                                   .withTime,
                                   .withDashSeparatorInDate,
                                   .withColonSeparatorInTime]

        Observable.shared.previousAlertLastLoopTime.value = Observable.shared.alertLastLoopTime.value

        if let lastPumpRecord = lastDeviceStatus?["pump"] as! [String: AnyObject]? {
            if let bolusIncrement = lastPumpRecord["bolusIncrement"] as? Double, bolusIncrement > 0 {
                Storage.shared.bolusIncrement.value = HKQuantity(unit: .internationalUnit(), doubleValue: bolusIncrement)
                Storage.shared.bolusIncrementDetected.value = true
            } else if let model = lastPumpRecord["model"] as? String, model == "Dash" {
                Storage.shared.bolusIncrement.value = HKQuantity(unit: .internationalUnit(), doubleValue: 0.05)
                Storage.shared.bolusIncrementDetected.value = true
            } else {
                Storage.shared.bolusIncrementDetected.value = false
            }

            if let clockString = lastPumpRecord["clock"] as? String,
               let lastPumpTime = formatter.date(from: clockString)?.timeIntervalSince1970
            {
                let storedTime = Observable.shared.alertLastLoopTime.value ?? 0
                if lastPumpTime > storedTime {
                    Observable.shared.alertLastLoopTime.value = lastPumpTime
                    Storage.shared.lastLoopTime.value = lastPumpTime
                }

                let reservoir = PumpReservoirResolver.resolve(
                    reservoir: lastPumpRecord["reservoir"] as? Double,
                    pumpID: lastPumpRecord["pumpID"] as? String,
                    manufacturer: lastPumpRecord["manufacturer"] as? String,
                    model: lastPumpRecord["model"] as? String,
                    cache: Storage.shared.pumpReservoirCache.value,
                    now: Date()
                )
                Storage.shared.pumpReservoirCache.value = reservoir.cache

                switch reservoir.state {
                case let .units(units):
                    latestPumpVolume = units
                    infoManager.updateInfoData(type: .pump, value: String(format: "%.0f", units) + "U", numericValue: units)
                    Storage.shared.lastPumpReservoirU.value = units
                case .aboveReportingLimit:
                    // Pumps that only report "50+" get treated as exactly 50, both
                    // for the volume alarm and for the info row's coloring.
                    latestPumpVolume = 50.0
                    infoManager.updateInfoData(type: .pump, value: "50+U", numericValue: 50.0)
                    Storage.shared.lastPumpReservoirU.value = nil
                case .unknown:
                    // The row stays cleared, which the info table renders as an em dash.
                    latestPumpVolume = nil
                    Storage.shared.lastPumpReservoirU.value = nil
                }
            }

            // Parse pump battery percentage
            if let pumpBatteryRecord = lastPumpRecord["battery"] as? [String: AnyObject],
               let pumpBatteryPercent = pumpBatteryRecord["percent"] as? Double
            {
                infoManager.updateInfoData(type: .pumpBattery, value: String(format: "%.0f", pumpBatteryPercent) + "%", numericValue: pumpBatteryPercent)
                Observable.shared.pumpBatteryLevel.value = pumpBatteryPercent
            }

            if let uploader = lastDeviceStatus?["uploader"] as? [String: AnyObject],
               let upbat = uploader["battery"] as? Double
            {
                let isCharging = uploader["isCharging"] as? Bool
                let batteryText: String
                if isCharging == true {
                    batteryText = "⚡️ " + String(format: "%.0f", upbat) + "%"
                } else {
                    batteryText = String(format: "%.0f", upbat) + "%"
                }
                infoManager.updateInfoData(type: .battery, value: batteryText, numericValue: upbat)
                Observable.shared.deviceBatteryLevel.value = upbat
                Observable.shared.deviceBatteryIsCharging.value = isCharging

                let timestamp = uploader["timestamp"] as? Date ?? Date()
                let currentBattery = DataStructs.batteryStruct(batteryLevel: upbat, timestamp: timestamp)
                deviceBatteryData.append(currentBattery)

                // store only the last 30 battery readings
                if deviceBatteryData.count > 30 {
                    deviceBatteryData.removeFirst()
                }
            }
        }

        // Loop - handle new data
        if let lastLoopRecord = lastDeviceStatus?["loop"] as! [String: AnyObject]? {
            // Some pumps report no `pump.clock`; without it alertLastLoopTime stays 0
            // and the forecast anchors to epoch 0. Fall back to the loop cycle timestamp.
            if (lastDeviceStatus?["pump"] as? [String: AnyObject])?["clock"] == nil,
               let loopTimestampString = lastLoopRecord["timestamp"] as? String,
               let loopTimestamp = formatter.date(from: loopTimestampString)?.timeIntervalSince1970,
               loopTimestamp > (Observable.shared.alertLastLoopTime.value ?? 0)
            {
                Observable.shared.alertLastLoopTime.value = loopTimestamp
                Storage.shared.lastLoopTime.value = loopTimestamp
            }

            DeviceStatusLoop(formatter: formatter, lastLoopRecord: lastLoopRecord)

            var oText = ""
            currentOverride = 1.0
            if let lastOverride = lastDeviceStatus?["override"] as? [String: AnyObject],
               let isActive = lastOverride["active"] as? Bool, isActive
            {
                if let lastCorrection = lastOverride["currentCorrectionRange"] as? [String: AnyObject],
                   let minValue = lastCorrection["minValue"] as? Double,
                   let maxValue = lastCorrection["maxValue"] as? Double
                {
                    if let multiplier = lastOverride["multiplier"] as? Double {
                        currentOverride = multiplier
                        oText += String(format: "%.0f%%", multiplier * 100)
                    } else {
                        oText += "100%"
                    }

                    oText += " ("
                    oText += Localizer.toDisplayUnits(String(minValue)) + "-" + Localizer.toDisplayUnits(String(maxValue)) + ")"
                }

                infoManager.updateInfoData(type: .override, value: oText)
            } else {
                infoManager.clearInfoData(type: .override)
            }
        }

        // OpenAPS - handle new data
        if let lastLoopRecord = lastDeviceStatus?["openaps"] as! [String: AnyObject]? {
            DeviceStatusOpenAPS(formatter: formatter, lastDeviceStatus: lastDeviceStatus, lastLoopRecord: lastLoopRecord)
        }

        // If the active looping system flipped (Loop ⇄ Trio/OpenAPS), drop the previous
        // system's forecast so it doesn't linger next to the one just drawn above.
        let currentDeviceIsLoop = Storage.shared.device.value == "Loop"
        if currentDeviceIsLoop != previousDeviceWasLoop {
            if currentDeviceIsLoop {
                clearOpenAPSPredictionGraph()
            } else {
                clearLoopPredictionGraph()
            }
        }

        // Start the timer based on the timestamp
        let now = dateTimeUtils.getNowTimeIntervalUTC()
        let secondsAgo = now - (Observable.shared.alertLastLoopTime.value ?? 0)

        DispatchQueue.main.async {
            var interval: Double
            if secondsAgo >= (20 * 60) {
                interval = 5 * 60
            } else if secondsAgo >= (10 * 60) {
                interval = 60
            } else if secondsAgo >= (7 * 60) {
                interval = 30
            } else if secondsAgo >= (5 * 60) {
                interval = 10
            } else {
                interval = 310 - secondsAgo
                TaskScheduler.shared.rescheduleTask(id: .alarmCheck, to: Date().addingTimeInterval(3))
            }

            if NightscoutSocketManager.shared.connectionState == .authenticated {
                interval = max(interval * 3, 60)
            }

            TaskScheduler.shared.rescheduleTask(
                id: .deviceStatus,
                to: Date().addingTimeInterval(interval)
            )
        }

        evaluateNotLooping()

        // Mark device status as loaded for initial loading state
        markDataLoaded("deviceStatus")

        if Storage.shared.contactEnabled.value, Storage.shared.contactIOB.value != .off,
           Observable.shared.iobText.value != previousIOBText
        {
            contactImageUpdater.updateContactImage(
                bgValue: Observable.shared.bgText.value,
                trend: Observable.shared.directionText.value,
                delta: Observable.shared.deltaText.value,
                iob: Observable.shared.iobText.value,
                stale: Observable.shared.bgStale.value
            )
        }

        LogManager.shared.log(category: .deviceStatus, message: "Update Device Status done", isDebug: true)
    }
}
