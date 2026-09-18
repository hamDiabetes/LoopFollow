// LoopFollow
// WidgetDataSource.swift

import Foundation

/// Supplies a timeline run with something current to draw.
///
/// Nightscout is the source; the App Group cache is what the widget falls back
/// to when the site cannot be reached, and what it starts from before the first
/// fetch of a run. It used to be the other way round, and that was the bug: the
/// cache is written by the app, so it stops advancing the moment iOS suspends
/// it, and a widget woken by the relay redrew the same reading it already had.
///
/// A run that fetches writes back everything it fetched: the reading, the chart
/// and the forecast are replaced, and the carbs and insulin series are appended
/// to. The reading caches used to be left to the app and the refresh button, and
/// that was the second half of the same bug — a cache only the foreground
/// advances is one this path can never find current, so the age check held off
/// nothing and every wake paid for a full fetch.
///
/// The carbs and insulin series are appended rather than replaced because the
/// app fills them only while it is awake and on a phone it rarely is. A series
/// that depends on the app running was always going to be sparse on the surface
/// that exists because the app is asleep, and the cycle it takes is one already
/// fetched for the reading. The stores merge rather than replace, and coordinate
/// across processes, for exactly this.
enum WidgetDataSource {
    /// WidgetKit can ask for a snapshot and a timeline back to back, and each
    /// arrives with the cache in the same state, so without this they would each
    /// go and fetch the same thing. Only helps within one process — the
    /// extension is often started fresh, and damping across processes would mean
    /// writing the cache. WidgetKit's own reload budget is the real limiter.
    private static let repeatWindow: TimeInterval = 45

    private actor RecentFetch {
        static let shared = RecentFetch()

        private var at: Date?
        private var outcome: WidgetNightscoutRefresh.Outcome?

        func recent(within window: TimeInterval) -> WidgetNightscoutRefresh.Outcome? {
            guard let at, let outcome, Date().timeIntervalSince(at) < window else { return nil }
            return outcome
        }

        func store(_ outcome: WidgetNightscoutRefresh.Outcome) {
            at = Date()
            self.outcome = outcome
        }
    }

    /// The chart series, the reading and the forecast, as current as this run
    /// could make them.
    ///
    /// A fetch that fails or brings nothing newer leaves all three exactly as
    /// they were cached. Half a fetch is never drawn over a whole cache: the
    /// three are replaced together or not at all, because the widget states one
    /// age over the reading and the metrics beside it, and a mixture would put
    /// that age over values from a different moment.
    static func load(duration: WidgetChartDuration) async -> (
        series: GlucoseChartSeries?,
        snapshot: GlucoseSnapshot?,
        prediction: GlucosePrediction?,
        ribbons: TreatmentRibbons?,
        target: TargetSeries?
    ) {
        // The profile is independent of everything else, so it goes out now.
        async let targetTask = target(duration: duration)

        // Readings first, and the ribbons strictly after, because `readings()`
        // adds this cycle to the carb and insulin stores and the ribbons are
        // read out of them. Run together, the read happened before the write
        // every time — the cycle a run paid for was never in the series that run
        // drew, so a phone waking every half hour added a sample that no render
        // ever saw. The cost is one fetch after another rather than alongside;
        // the alternative was a change that could not take effect.
        let (series, snapshot, prediction) = await readings()
        let ribbons = await ribbons(duration: duration)
        return (series, snapshot, prediction, ribbons, await targetTask)
    }

    private static func readings() async -> (series: GlucoseChartSeries?, snapshot: GlucoseSnapshot?, prediction: GlucosePrediction?) {
        await appGroupCache.readings { stored in
            let outcome: WidgetNightscoutRefresh.Outcome
            if let recent = await RecentFetch.shared.recent(within: repeatWindow) {
                outcome = recent
            } else {
                outcome = await WidgetNightscoutRefresh.fetch(newerThan: stored)
                await RecentFetch.shared.store(outcome)
            }

            guard case let .refreshed(payload) = outcome else { return nil }

            // The cycle this run just paid for, added to the series the widget
            // is about to draw from — and awaited, because the caller reads
            // those stores the moment this returns. The refresh button has
            // always awaited its saves for exactly this reason; this path used
            // to say the render did not wait on it, and was wrong about the same
            // two stores.
            await append(payload)

            return WidgetReadingCache.Reading(
                series: payload.series,
                snapshot: payload.snapshot,
                prediction: payload.prediction
            )
        }
    }

    /// The reading cache wired to the App Group files.
    ///
    /// Written in the order the refresh button writes them — forecast, chart,
    /// reading — so that a process stopped part way leaves something older under
    /// something newer, which is the state the widget already lives in whenever
    /// its cache runs stale and which its age line describes correctly.
    private static let appGroupCache = WidgetReadingCache(
        load: {
            (
                GlucoseChartSeriesStore.shared.load(),
                GlucoseSnapshotStore.shared.load(),
                GlucosePredictionStore.shared.load()
            )
        },
        save: { reading in
            await save(reading.prediction)
            await save(reading.series)
            await save(reading.snapshot)
        }
    )

    private static func save(_ series: GlucoseChartSeries) async {
        await withCheckedContinuation { continuation in
            GlucoseChartSeriesStore.shared.save(series) { continuation.resume() }
        }
    }

    private static func save(_ snapshot: GlucoseSnapshot) async {
        await withCheckedContinuation { continuation in
            GlucoseSnapshotStore.shared.save(snapshot) { continuation.resume() }
        }
    }

    private static func save(_ prediction: GlucosePrediction?) async {
        await withCheckedContinuation { continuation in
            guard let prediction else {
                GlucosePredictionStore.shared.clear { continuation.resume() }
                return
            }
            GlucosePredictionStore.shared.save(prediction) { continuation.resume() }
        }
    }

    /// Insulin, carbs on board and rescue carbs, for the chart's ribbons.
    ///
    /// Insulin and rescue carbs are fetched every run. The app does not gather
    /// those, so an App Group copy could only ever hold what some earlier widget
    /// run put there, and a widget that has not run lately is the one case they
    /// would be wrong in.
    ///
    /// Carbs on board is read from the store instead. The app receives every
    /// figure the loop publishes and `CarbsOnBoardStore` retains them, so the
    /// series costs nothing here — where fetching it meant a window of
    /// devicestatus records, each carrying a whole forecast, on every refresh.
    /// What the store cannot cover it leaves out, and the chart draws a gap
    /// rather than a flat ribbon over a stretch nothing was watching.
    ///
    /// The treatments reach a little further back than the span: a rescue entry
    /// from just before the left edge is still absorbing inside it.
    ///
    /// Nil rather than empty when nothing landed, so a failed fetch draws no
    /// ribbon rather than three flat ones claiming nothing happened.
    private static func ribbons(duration: WidgetChartDuration) async -> TreatmentRibbons? {
        let url = LAAppGroupSettings.nightscoutURL()
        guard !url.isEmpty else { return nil }
        let token = LAAppGroupSettings.nightscoutToken()

        let window = duration.seconds
        // The store says where it was watching as well as what it saw, so this
        // surface reads an absence the same way the lock screen does rather than
        // falling through to the twenty minute hold.
        // The grid is built from the samples that are handed over, not from the
        // store it came out of. A grid whose stretches start earlier than the
        // samples do leaves moments inside a stretch with nothing before them,
        // and the sampler answers those with a reported zero — a figure nobody
        // published. The carb series trims and the insulin series does not, and
        // the trim only avoided that by keeping one sample from before the
        // window; deriving both from one array is what makes it safe rather than
        // lucky.
        let history = CarbsOnBoardStore.shared.load()
        let insulin = InsulinOnBoardStore.shared.load()
        let carbSamples = carbsOnBoardHistory(history, window: window)
        let carbGrid = carbSamples.map { CarbsOnBoardHistory(samples: $0, updatedAt: $0.last?.date ?? Date()).grid() } ?? nil
        // The rescue ribbon's decay is anchored to the profile's own carb rate,
        // so the profile is asked for alongside the treatments. One more narrow
        // query on a path that already makes several, and the alternative is a
        // rate this chart invented.
        async let profileTask = NightscoutTreatmentsFetcher.profile(baseURL: url, token: token)
        let ribbons = await NightscoutTreatmentsFetcher.ribbons(
            baseURL: url,
            token: token,
            lookback: window + RescueAbsorption.duration,
            carbsOnBoard: carbSamples,
            carbsObserved: carbGrid,
            insulinOnBoard: insulin?.samples,
            insulinObserved: insulin?.grid(),
            carbsPerHour: await profileTask?.carbsPerHour
        )
        return ribbons.isEmpty ? nil : ribbons
    }

    /// The retained carbs-on-board samples inside the span being drawn.
    ///
    /// One sample before the left edge is kept as well, since the loop holds a
    /// figure between cycles and the ribbon's left edge would otherwise start
    /// blank until the first sample inside the window.
    ///
    /// Nil when there is no store to read, which is a chart that does not know
    /// rather than one with nothing to show. An empty array would be the same
    /// claim the fetch this replaced used to make on a failed request.
    private static func carbsOnBoardHistory(_ history: CarbsOnBoardHistory?, window: TimeInterval) -> [CarbsOnBoardSample]? {
        guard let samples = history?.samples else { return nil }
        let start = Date().addingTimeInterval(-window)
        guard let firstInside = samples.firstIndex(where: { $0.date >= start }) else {
            return Array(samples.suffix(1))
        }
        return Array(samples[max(0, firstInside - 1)...])
    }

    /// The target the loop is aiming at, out of the profile's own schedule.
    ///
    /// Fetched here rather than waiting for the relay: this surface never goes
    /// through it, so there is nothing to agree and no capability to claim. The
    /// lock screen gains the line when the relay's half is deployed.
    ///
    /// Nil where the profile aims at a band rather than a line, which is a
    /// chart-wide question rather than something to average away.
    private static func target(duration: WidgetChartDuration) async -> TargetSeries? {
        let url = LAAppGroupSettings.nightscoutURL()
        guard !url.isEmpty else { return nil }

        guard let profile = await NightscoutTreatmentsFetcher.profile(
            baseURL: url,
            token: LAAppGroupSettings.nightscoutToken()
        ), let schedule = profile.targetSchedule else { return nil }

        let now = Date()
        let series = schedule.series(
            from: now.addingTimeInterval(-duration.seconds),
            to: now,
            timezone: profile.timezone ?? .current
        )
        return series.isEmpty ? nil : series
    }

    /// Adds this cycle to both series and waits for it to land.
    private static func append(_ payload: WidgetNightscoutRefresh.Payload) async {
        if let carbs = payload.carbsOnBoard {
            await withCheckedContinuation { continuation in
                CarbsOnBoardStore.shared.append(carbs) { _ in continuation.resume() }
            }
        }
        if let insulin = payload.insulinOnBoard {
            await withCheckedContinuation { continuation in
                InsulinOnBoardStore.shared.append(insulin) { _ in
                    continuation.resume()
                }
            }
        }
    }
}
