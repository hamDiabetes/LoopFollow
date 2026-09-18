// LoopFollow
// ChartReviewView.swift

#if DEBUG

    import Charts
    import SwiftUI

    /// Draws the real chart from a real Nightscout, so a change can be looked at
    /// without putting a build on somebody's phone.
    ///
    /// **Everything here goes through the code the surfaces use.** Readings come
    /// from `NightscoutChartFetcher`, treatments and the profile from
    /// `NightscoutTreatmentsFetcher`, and the series are assembled into the same
    /// `TreatmentRibbons` and `TargetSeries` the widget builds. The only thing
    /// written here is the devicestatus read for carbs and insulin on board,
    /// which the surfaces get from their stores — a store is filled by a device
    /// over hours and cannot be borrowed, so the figures are read from the same
    /// records the app reads them from, one field each and no rules restated.
    ///
    /// That distinction is the point: a harness that reimplements what it is
    /// checking agrees with the original everywhere except where the original is
    /// interesting.
    ///
    /// **Two limits it cannot remove, and one it now can.**
    ///
    /// It runs in the foreground app, which fills the stores on every poll, so
    /// it reads them in exactly the state where the sparse-store failure cannot
    /// happen — a complete ribbon here says nothing about a phone whose widget
    /// draws none. `lfReviewThinMinutes` exists for that: it decimates the store
    /// to a stated spacing before handing it over, so the failure can be made to
    /// appear on demand rather than waited for.
    ///
    /// And it renders the same view for both panels, so a Live Activity panel
    /// here is the widget's drawing on a coloured ground. It cannot tell the two
    /// producers apart, because the producer is the one thing it does not vary:
    /// the dose fallback looks identical in either.
    ///
    /// DEBUG only, and reached only when `lfChartReview` is set in the app's
    /// defaults, so it cannot be arrived at by tapping.
    struct ChartReviewView: View {
        @State private var loaded: Loaded?
        @State private var failure: String?

        struct Loaded {
            let series: GlucoseChartSeries
            let ribbons: TreatmentRibbons
            let target: TargetSeries?
            let prediction: GlucosePrediction?
            let note: String
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                    } else if let loaded {
                        Text(loaded.note).font(.caption2).foregroundStyle(.secondary)
                        panel("Widget, 158 pt", loaded, tint: Color(.secondarySystemBackground), tinted: false, height: 158)
                        panel("Live Activity, in range", loaded, tint: .green.opacity(0.75), tinted: true, height: 160)
                        panel("Live Activity, high", loaded, tint: .orange.opacity(0.8), tinted: true, height: 160)
                        panel("Live Activity, low", loaded, tint: .red.opacity(0.8), tinted: true, height: 160)
                    } else {
                        Text("loading…").font(.caption)
                    }
                }
                .padding(10)
            }
            .task { await load() }
        }

        private func panel(
            _ label: String,
            _ loaded: Loaded,
            tint: Color,
            tinted: Bool,
            height: CGFloat
        ) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                WidgetChartView(
                    series: loaded.series,
                    unit: .mgdl,
                    duration: Self.duration,
                    // From the settings, like every argument here that the
                    // shipping surfaces read from settings. Pinned values made
                    // the instrument draw a chart nobody has: the placement pin
                    // survived the placement being changed, and `prediction:
                    // nil` meant the forecast never appeared at all — so the one
                    // thing this could not show was the ribbons and the forecast
                    // sharing the plot, which is where the height question
                    // lives. `duration` stays a knob because reviewing a span is
                    // the point of it.
                    style: LAAppGroupSettings.chartStyle(),
                    prediction: loaded.prediction,
                    ribbons: loaded.ribbons,
                    horizon: LAAppGroupSettings.predictionHorizon(),
                    now: Self.end,
                    bottomReserve: tinted ? 46 : 50,
                    topReserve: tinted ? 14 : 16,
                    onTintedBackground: tinted,
                    target: loaded.target
                )
                .frame(height: height)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }

        // MARK: - What to draw

        private static var defaults: UserDefaults { .standard }

        /// The moment the chart is drawn as of, so a particular minute can be
        /// re-examined rather than only the present one.
        static var end: Date {
            let minutesAgo = defaults.double(forKey: "lfReviewMinutesAgo")
            return Date().addingTimeInterval(-minutesAgo * 60)
        }

        /// Thins the stores to this spacing before drawing, in minutes, so the
        /// sparse-phone case can be reproduced from a foreground app that would
        /// otherwise never show it. Zero leaves them alone.
        static var thinMinutes: Double { defaults.double(forKey: "lfReviewThinMinutes") }

        static var duration: WidgetChartDuration {
            switch defaults.double(forKey: "lfReviewHours") {
            case 0 ..< 2: return .oneHour
            case 2 ..< 4: return .threeHours
            case 4 ..< 8: return .sixHours
            case 8 ..< 16: return .twelveHours
            default: return .twentyFourHours
            }
        }

        // MARK: - Loading

        private func load() async {
            let url = Self.defaults.string(forKey: "lfReviewURL") ?? LAAppGroupSettings.nightscoutURL()
            let token = Self.defaults.string(forKey: "lfReviewToken") ?? LAAppGroupSettings.nightscoutToken()
            guard !url.isEmpty else {
                failure = "no site: set lfReviewURL"
                return
            }

            // A synthetic series with a fixed insulin figure and a
            // trace that goes flat, steeply up, flat, steeply down. Constant
            // input, so any change in the ribbon's apparent width across it is
            // the geometry and nothing else.
            // Switched on with lfReviewShear. Real data cannot answer a
            // question about geometry, because its slope and its figures move
            // together; here the figures are pinned and only the slope varies,
            // so anything that changes across the window is the drawing.
            if Self.defaults.bool(forKey: "lfReviewShear") {
                let end = Self.end
                var points: [GlucoseChartPoint] = []
                var insulin: [InsulinOnBoardSample] = []
                let count = 36
                for index in 0 ..< count {
                    let date = end.addingTimeInterval(-Double(count - 1 - index) * 300)
                    let value: Double
                    switch index {
                    case 0 ..< 9: value = 120
                    case 9 ..< 18: value = 120 + Double(index - 9) * 22
                    case 18 ..< 27: value = 318
                    default: value = max(80, 318 - Double(index - 27) * 26)
                    }
                    points.append(GlucoseChartPoint(value: value, date: date))
                    insulin.append(InsulinOnBoardSample(date: date, units: 2))
                }
                let history = InsulinOnBoardHistory(samples: insulin, updatedAt: end)
                loaded = Loaded(
                    series: GlucoseChartSeries(points: points, updatedAt: end),
                    ribbons: TreatmentRibbons(
                        insulin: [],
                        carbsOnBoard: insulin.map { CarbsOnBoardSample(date: $0.date, grams: 40) },
                        rescue: [],
                        coveredFrom: points.first?.date,
                        carbsObserved: CarbsOnBoardHistory(samples: insulin.map { CarbsOnBoardSample(date: $0.date, grams: 40) }, updatedAt: end).grid(),
                        insulinOnBoard: insulin,
                        insulinObserved: history.grid()
                    ),
                    target: nil,
                    prediction: nil,
                    note: "SYNTHETIC: constant 2 U insulin on board and 40 g carbs across a flat, a steep rise, a flat and a steep fall"
                )
                return
            }

            guard let entries = await NightscoutChartFetcher.fetch(baseURL: url, token: token) else {
                failure = "readings did not land"
                return
            }

            let end = Self.end
            let window = Self.duration.seconds
            let cycles = await Self.cycles(baseURL: url, token: token, since: end.addingTimeInterval(-window - 3600), until: end)
            let carbs = cycles.compactMap { cycle in
                cycle.carbs.map { CarbsOnBoardSample(date: cycle.date, grams: $0) }
            }
            let insulin = cycles.compactMap { cycle in
                cycle.insulin.map { InsulinOnBoardSample(date: cycle.date, units: $0) }
            }
            let profile = await NightscoutTreatmentsFetcher.profile(baseURL: url, token: token)

            // The store is what the widget actually reads, so it wins where it
            // exists. Devicestatus is the fallback and it is the harness's one
            // shortcut: it produces a complete series where a device's store is
            // whatever that device managed to collect, so a green picture from
            // the fallback says nothing about the path that feeds the phone.
            // Which source was used is in the caption, because a tool whose
            // blind spot is where the bug lives is worse than no tool.
            let storedCarbs = CarbsOnBoardStore.shared.load()
            let storedInsulin = InsulinOnBoardStore.shared.load()
            let carbSource = storedCarbs.map { _ in "store" } ?? "devicestatus"
            let insulinSource = storedInsulin.map { _ in "store" } ?? "devicestatus"

            let carbHistory = Self.thinned(storedCarbs ?? CarbsOnBoardHistory(samples: carbs, updatedAt: carbs.last?.date ?? end))
            let insulinHistory = Self.thinned(storedInsulin ?? InsulinOnBoardHistory(
                samples: insulin,
                updatedAt: insulin.last?.date ?? end
            ))

            let ribbons = await NightscoutTreatmentsFetcher.ribbons(
                baseURL: url,
                token: token,
                // Measured back from the minute being reviewed, not from now.
                // The fetcher states its coverage from the moment it runs,
                // because every shipping surface draws the present; this one
                // does not. Asking for the window alone put `coveredFrom` hours
                // after everything on screen, and `covers` then rejected every
                // reading — the chart drew no ribbons at all and the harness
                // said nothing about why. It is in the caption now.
                lookback: Date().timeIntervalSince(end) + window + RescueAbsorption.maxDuration,
                // As the widget hands them over: trimmed to the window, and the
                // array rather than nil when it is empty — nil would pick the
                // dose fallback here and the on-board series there.
                carbsOnBoard: carbHistory.samples,
                carbsObserved: carbHistory.grid(),
                insulinOnBoard: insulinHistory.samples,
                insulinObserved: insulinHistory.grid(),
                carbsPerHour: profile?.carbsPerHour
            )

            let target = profile?.targetSchedule?.series(
                from: end.addingTimeInterval(-window),
                to: end,
                timezone: profile?.timezone ?? .current
            )

            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            // From the store the app writes on its own polls, which is what the
            // Live Activity draws from too. The harness cannot parse a forecast
            // of its own without restating the clamping the app does, and a
            // harness that restates what it is checking agrees with the original
            // everywhere except where the original is interesting.
            let prediction = GlucosePredictionStore.shared.load()

            loaded = Loaded(
                series: entries.series,
                ribbons: ribbons,
                target: (target?.isEmpty ?? true) ? nil : target,
                prediction: prediction,
                note: [
                    "as of \(formatter.string(from: end))",
                    "\(entries.series.points.count) readings",
                    "IOB \(insulinHistory.samples.count) from \(insulinSource) (latest \(insulinHistory.samples.last.map { String(format: "%.2f U", $0.units) } ?? "none"))",
                    "COB \(carbHistory.samples.count) from \(carbSource)",
                    "devicestatus had IOB \(insulin.count) / COB \(carbs.count)",
                    Self.thinMinutes > 0 ? "thinned to \(Int(Self.thinMinutes)) min" : "not thinned",
                    "forecast \(prediction.map { "\($0.curves.count) curves" } ?? "none")",
                    {
                        let visible = entries.series.points.filter { $0.date >= end.addingTimeInterval(-window) && $0.date <= end }
                        let covered = visible.filter { point in ribbons.coveredFrom.map { point.date >= $0 } ?? true }
                        return "covered \(covered.count)/\(visible.count) readings"
                    }(),
                    "insulin events \(ribbons.insulin?.count ?? -1)",
                    "rescue \(ribbons.rescue?.count ?? -1)",
                    "IOB scale \(String(format: "%.1f U", LAAppGroupSettings.insulinFullScaleUnits())) at \(String(format: "%.0f%%", LAAppGroupSettings.insulinHeightShare() * 100))",
                    "carbs_hr \(profile?.carbsPerHour.map { String(format: "%.0f", $0) } ?? "none")",
                ].joined(separator: " · ")
            )
        }

        /// Keeps one sample per `thinMinutes`, which is what a phone that wakes
        /// rarely leaves behind.
        static func thinned(_ history: CarbsOnBoardHistory) -> CarbsOnBoardHistory {
            guard thinMinutes > 0 else { return history }
            return CarbsOnBoardHistory(samples: thin(history.samples, by: \.date), updatedAt: history.updatedAt)
        }

        static func thinned(_ history: InsulinOnBoardHistory) -> InsulinOnBoardHistory {
            guard thinMinutes > 0 else { return history }
            return InsulinOnBoardHistory(
                samples: thin(history.samples, by: \.date),
                updatedAt: history.updatedAt
            )
        }

        private static func thin<S>(_ samples: [S], by date: (S) -> Date) -> [S] {
            var kept: [S] = []
            for sample in samples {
                guard let last = kept.last else { kept.append(sample); continue }
                if date(sample).timeIntervalSince(date(last)) >= thinMinutes * 60 { kept.append(sample) }
            }
            return kept
        }

        /// One loop cycle's figures, straight off the record.
        ///
        /// The surfaces read these from their stores, which a harness cannot
        /// borrow — a store is filled by one device over hours. So they are read
        /// from the records the app reads them from, taking the fields and
        /// nothing else.
        struct Cycle {
            let date: Date
            let carbs: Double?
            let insulin: Double?
            let tdd: Double?
        }

        static func cycles(baseURL: String, token: String, since: Date, until: Date) async -> [Cycle] {
            var components = URLComponents(string: baseURL)
            components?.path = "/api/v1/devicestatus.json"
            var items = [URLQueryItem(name: "count", value: "800")]
            if !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
            items.append(URLQueryItem(name: "find[created_at][$gte]", value: ISO8601DateFormatter().string(from: since)))
            components?.queryItems = items
            guard let url = components?.url else { return [] }

            var request = URLRequest(url: url)
            request.setValue("LoopFollow-ChartReview", forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return [] }

            return records.compactMap { record -> Cycle? in
                guard let openaps = record["openaps"] as? [String: Any] else { return nil }
                let suggested = (openaps["suggested"] as? [String: Any]) ?? (openaps["enacted"] as? [String: Any])
                let stamp = (suggested?["timestamp"] as? String) ?? (record["created_at"] as? String)
                guard let stamp, let date = NightscoutDate.eventDate(["created_at": stamp]), date <= until else { return nil }
                return Cycle(
                    date: date,
                    carbs: (suggested?["COB"] as? NSNumber)?.doubleValue,
                    insulin: ((openaps["iob"] as? [String: Any])?["iob"] as? NSNumber)?.doubleValue,
                    tdd: (suggested?["TDD"] as? NSNumber)?.doubleValue
                )
            }
            .sorted { $0.date < $1.date }
        }
    }

#endif
