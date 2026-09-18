// LoopFollow
// NightscoutTreatmentsFetcher.swift

import Foundation

/// The fields that come from treatments and the profile rather than from the
/// loop's own status record: the sensor, cannula and insulin ages, carbs today,
/// an active override or temporary target, the profile name and its scheduled
/// basal.
///
/// Every field is independently optional. Each one is populated only when the
/// request that sources it landed, so an absent value means "not known right
/// now" rather than "known to be nothing" — and never a value carried forward
/// from a fetch that already happened.
struct NightscoutTreatmentState {
    /// Zero rather than nil, matching the snapshot's own encoding of "not set".
    var sageInsertTime: TimeInterval = 0
    var cageInsertTime: TimeInterval = 0
    var iageInsertTime: TimeInterval = 0

    var carbsToday: Double?
    var override: String?

    /// Nil alongside a non-nil `override` means indefinite, which the card
    /// renders as a name with no countdown.
    var overrideEndAt: TimeInterval?

    var tempTargetMgdl: Double?
    var tempTargetEndAt: TimeInterval?

    var profileName: String?
    var targetLowMgdl: Double?
    var targetHighMgdl: Double?

    /// What the profile schedules for right now, in units per hour. Used only
    /// when the loop is not running a temp basal over the top of it.
    var scheduledBasal: Double?
}

/// Rebuilds `NightscoutTreatmentState` from Nightscout, for the widget paths
/// that run while the app is asleep.
///
/// In `Shared/` rather than in the widget extension that uses it, for the reason
/// `NightscoutDate` moved there first: nothing in the extension is reachable
/// from a test target, and the pieces worth testing kept having to be carved out
/// one at a time. It compiles into the app as well, which is also what lets the
/// review harness drive the real fetch rather than a copy of its rules.
///
/// This is a port of the relay's `treatments.js` and `nightscoutRest.js`, which
/// were themselves ported from the app's `Treatments.swift` and verified against
/// this family's production site. The event type spellings, the cancel-record
/// rule for temporary targets, the indefinite-override rule and the timezone the
/// day boundary follows are all carried over deliberately: two surfaces
/// disagreeing about when a sensor was inserted is worse than either being
/// wrong on its own, because it gives no way to tell which to believe.
///
/// Where it departs from the relay is in what it asks for. The relay pulls a
/// 36-hour window of everything — 93 KB and 407 records on this site — and
/// derives from that. A widget extension has a small memory ceiling and is
/// killed shortly after it returns, so this asks each field's own question
/// instead and downloads about 5 KB. That is also safer: a single windowed query
/// has to be capped, and a busy fortnight silently trims the record that mattered
/// off the end, which reads as "never happened" rather than as an error.
enum NightscoutTreatmentsFetcher {
    static let timeout: TimeInterval = 4

    /// Long enough to cover carbs since any plausible midnight with room for a
    /// clock skew either way. Matches the relay's window.
    static let carbLookback: TimeInterval = 36 * 3600

    /// Types whose newest record is the whole answer. One query each: see the
    /// note above about capped windows.
    private static let ageEventTypes: [(String, WritableKeyPath<NightscoutTreatmentState, TimeInterval>)] = [
        ("Sensor Start", \.sageInsertTime),
        ("Site Change", \.cageInsertTime),
        ("Pump Site Change", \.cageInsertTime),
        ("Insulin Change", \.iageInsertTime),
    ]

    /// Types describing something that may still be running. More than one is
    /// fetched because the newest of them can have ended while an older one has
    /// not — an override with no duration runs until it is cancelled.
    private static let overrideEventTypes = ["Temporary Override", "Exercise"]
    private static let tempTargetEventType = "Temporary Target"
    private static let activeEventCount = 10

    // MARK: - Public API

    /// Nil only when nothing at all landed. A state with some fields nil is the
    /// normal result on a site that has never recorded an override.
    static func fetch(baseURL: String, token: String) async -> NightscoutTreatmentState? {
        guard !baseURL.isEmpty else { return nil }

        // Every request is independent and a reload waits on the whole set, so
        // they go out together rather than one after another.
        async let profileTask = profile(baseURL: baseURL, token: token)
        async let carbsTask = carbTreatments(baseURL: baseURL, token: token)
        async let overrideTask = treatments(baseURL: baseURL, token: token, eventTypes: overrideEventTypes, count: activeEventCount)
        async let tempTargetTask = treatments(baseURL: baseURL, token: token, eventTypes: [tempTargetEventType], count: activeEventCount)
        async let agesTask = latestByEventType(baseURL: baseURL, token: token)

        let profileDoc = await profileTask
        let carbs = await carbsTask
        let overrides = await overrideTask
        let tempTargets = await tempTargetTask
        let ages = await agesTask

        let landed = profileDoc != nil || carbs != nil || overrides != nil || tempTargets != nil || ages != nil
        guard landed else { return nil }

        var state = NightscoutTreatmentState()

        if let ages {
            state.sageInsertTime = ages.sageInsertTime
            state.cageInsertTime = ages.cageInsertTime
            state.iageInsertTime = ages.iageInsertTime
        }
        if let profileDoc {
            state.profileName = profileDoc.name
            state.targetLowMgdl = profileDoc.targetLowMgdl
            state.targetHighMgdl = profileDoc.targetHighMgdl
            state.scheduledBasal = profileDoc.scheduledBasal
        }
        if let overrides, let active = activeOverride(in: overrides) {
            state.override = active.name
            state.overrideEndAt = active.endAt
        }
        if let tempTargets, let active = activeTempTarget(in: tempTargets) {
            state.tempTargetMgdl = active.targetMgdl
            state.tempTargetEndAt = active.endAt
        }
        if let carbs {
            // The day boundary follows the profile's timezone where there is
            // one, as the relay's does. Without a profile it follows the phone's,
            // which is where the person reading the widget is standing — a better
            // fallback than the relay's own, not a worse one.
            state.carbsToday = sumCarbsToday(carbs, timezone: profileDoc?.timezone ?? .current)
        }

        return state
    }

    // MARK: - Derivation

    struct ActiveOverride {
        let name: String
        let endAt: TimeInterval?
    }

    /// The override in force now: the most recently started one that has not
    /// already ended. An override with no duration is indefinite, so it keeps a
    /// nil `endAt` rather than being given one of "now".
    static func activeOverride(in treatments: [[String: Any]], now: Date = Date()) -> ActiveOverride? {
        var best: (name: String, startedAt: Date, endAt: TimeInterval?)?

        for treatment in treatments {
            guard overrideEventTypes.contains(eventType(treatment)) else { continue }
            guard let started = NightscoutDate.eventDate(treatment), started <= now else { continue }

            let minutes = (treatment["duration"] as? NSNumber)?.doubleValue
            let ends = (minutes ?? 0) > 0 ? started.addingTimeInterval(minutes! * 60) : nil
            if let ends, ends <= now { continue }

            if best == nil || started > best!.startedAt {
                let name = (treatment["reason"] as? String)
                    ?? (treatment["notes"] as? String)
                    ?? eventType(treatment)
                best = (name, started, ends?.timeIntervalSince1970)
            }
        }

        guard let best, !best.name.isEmpty else { return nil }
        return ActiveOverride(name: best.name, endAt: best.endAt)
    }

    struct ActiveTempTarget {
        let targetMgdl: Double
        let endAt: TimeInterval
    }

    /// The temporary target in force now.
    ///
    /// Only the newest record is considered, whatever its duration. Nightscout
    /// writes a cancel as a `Temporary Target` of zero duration, so a newer zero
    /// ends the target before it rather than leaving that one running.
    static func activeTempTarget(in treatments: [[String: Any]], now: Date = Date()) -> ActiveTempTarget? {
        var newest: (record: [String: Any], startedAt: Date)?

        for treatment in treatments {
            guard eventType(treatment) == tempTargetEventType else { continue }
            guard let started = NightscoutDate.eventDate(treatment), started <= now else { continue }
            if newest == nil || started > newest!.startedAt {
                newest = (treatment, started)
            }
        }

        guard let newest else { return nil }
        let minutes = (newest.record["duration"] as? NSNumber)?.doubleValue ?? 0
        guard minutes > 0 else { return nil }

        let ends = newest.startedAt.addingTimeInterval(minutes * 60)
        guard ends > now else { return nil }

        let bottom = mgdl(newest.record["targetBottom"])
        let top = mgdl(newest.record["targetTop"])
        guard let target = bottom ?? top else { return nil }

        return ActiveTempTarget(targetMgdl: target, endAt: ends.timeIntervalSince1970)
    }

    /// Carbs entered since midnight in the given zone.
    static func sumCarbsToday(_ treatments: [[String: Any]], timezone: TimeZone, now: Date = Date()) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startOfDay = calendar.startOfDay(for: now)

        return treatments.reduce(into: 0.0) { total, treatment in
            guard let carbs = (treatment["carbs"] as? NSNumber)?.doubleValue, carbs > 0 else { return }
            guard let date = NightscoutDate.eventDate(treatment), date >= startOfDay, date <= now else { return }
            total += carbs
        }
    }

    // MARK: - Requests

    private struct Ages {
        var sageInsertTime: TimeInterval = 0
        var cageInsertTime: TimeInterval = 0
        var iageInsertTime: TimeInterval = 0
    }

    /// One `count=1` query per type, run together. Both spellings of a site
    /// change write the same field, so whichever is newer wins.
    private static func latestByEventType(baseURL: String, token: String) async -> Ages? {
        await withTaskGroup(of: (WritableKeyPath<NightscoutTreatmentState, TimeInterval>, Date?)?.self) { group in
            for (eventType, keyPath) in ageEventTypes {
                group.addTask {
                    guard let records = await treatments(baseURL: baseURL, token: token, eventTypes: [eventType], count: 1) else {
                        return nil
                    }
                    return (keyPath, records.compactMap(NightscoutDate.eventDate).max())
                }
            }

            var ages = Ages()
            var landed = false
            for await result in group {
                guard let (keyPath, date) = result else { continue }
                landed = true
                guard let seconds = date?.timeIntervalSince1970 else { continue }
                switch keyPath {
                case \NightscoutTreatmentState.sageInsertTime: ages.sageInsertTime = max(ages.sageInsertTime, seconds)
                case \NightscoutTreatmentState.cageInsertTime: ages.cageInsertTime = max(ages.cageInsertTime, seconds)
                default: ages.iageInsertTime = max(ages.iageInsertTime, seconds)
                }
            }
            return landed ? ages : nil
        }
    }

    /// Carb-bearing treatments only. Asking for the carbs rather than for a
    /// window is what keeps this at a few kilobytes: on this site the same
    /// window unfiltered is 93 KB.
    private static func carbTreatments(baseURL: String, token: String) async -> [[String: Any]]? {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-carbLookback))
        return await getTreatments(baseURL: baseURL, token: token, count: 200, items: [
            URLQueryItem(name: "find[carbs][$gte]", value: "1"),
            URLQueryItem(name: "find[created_at][$gte]", value: since),
        ])
    }

    /// How far back the ribbons are drawn when the caller does not say. The
    /// chart's longest window is a day.
    static let ribbonLookback: TimeInterval = 24 * 3600

    /// Marks a rescue-carb entry. Rescue carbs are logged as notes with no
    /// `carbs` field so the loop never doses for them, which also means they are
    /// invisible to every other query here — and the site's other notes are
    /// Trio's own pump-suspend records, so the event type alone would pull those
    /// in instead.
    /// Read by the main chart too, which discriminates the same way against
    /// the notes the app has already downloaded. One definition, because two
    /// that disagree show up as a ribbon on one surface and not the other and
    /// read as a rendering fault rather than a parsing one.
    static let rescueCarbApp = "rescue-carbs"

    /// Grams out of the note text, which is the only place they exist.
    private static let rescueCarbGrams = try! NSRegularExpression(pattern: #"Rescue carbs: (\d+(?:\.\d+)?) g"#)

    /// Insulin and rescue carbs, for the chart's ribbons.
    ///
    /// Two trips rather than one window: unfiltered, a day of treatments on
    /// this site runs to tens of kilobytes, and the widget pays for that on
    /// every refresh.
    ///
    /// Carbs on board is passed in rather than fetched. It is published in
    /// devicestatus, where a record carries the whole forecast as well, so
    /// reading a window of them cost more than everything else this file asks
    /// for put together. The app receives the same figures on its own poll, and
    /// `CarbsOnBoardStore` retains them.
    ///
    /// Both queries are capped, so both report how far back they actually read.
    /// A cap is not a promise about the window: the busiest real day here is 128
    /// records against the 400 asked for, but a day that reached the cap would
    /// have its oldest hours cut off silently, and the chart would draw no
    /// insulin across them rather than saying it had not looked.
    static func ribbons(
        baseURL: String,
        token: String,
        lookback: TimeInterval = ribbonLookback,
        carbsOnBoard: [CarbsOnBoardSample]?,
        carbsObserved: ObservedGrid? = nil,
        insulinOnBoard: [InsulinOnBoardSample]? = nil,
        insulinObserved: ObservedGrid? = nil,
        carbsPerHour: Double? = nil
    ) async -> TreatmentRibbons {
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-lookback))

        async let insulinRecords = getTreatments(baseURL: baseURL, token: token, count: insulinCount, items: [
            URLQueryItem(name: "find[insulin][$gte]", value: "0.01"),
            URLQueryItem(name: "find[created_at][$gte]", value: since),
        ])
        async let rescueRecords = getTreatments(baseURL: baseURL, token: token, count: rescueCount, items: [
            URLQueryItem(name: "find[app]", value: rescueCarbApp),
            URLQueryItem(name: "find[created_at][$gte]", value: since),
        ])

        // Each series keeps its own nil. A request that did not land is not a
        // window in which nothing was given, and the two have to stay apart all
        // the way to the chart.
        let insulin = (await insulinRecords)?.compactMap { record -> TreatmentEvent? in
            guard let amount = (record["insulin"] as? NSNumber)?.doubleValue, amount > 0,
                  let date = NightscoutDate.eventDate(record) else { return nil }
            return TreatmentEvent(date: date, amount: amount)
        }

        let rescue = (await rescueRecords)?.compactMap { record -> TreatmentEvent? in
            guard let notes = record["notes"] as? String,
                  let grams = rescueGrams(from: notes),
                  let date = NightscoutDate.eventDate(record) else { return nil }
            return TreatmentEvent(date: date, amount: grams)
        }

        // Counted on the records and dated from what parsed, which is why the
        // two are passed separately. A record dropped here for want of a usable
        // amount still proves the query read that far back, so handing over a
        // compacted array would let one undated record shorten the count below
        // the cap and report a truncated answer as a complete one — wrong in the
        // direction that looks safe, and what this did until it was measured.
        //
        // Not binding on this site: the busiest rolling day is 128 records
        // against the 400 asked for, and none of 1920 insulin records lacks a
        // date. Both are one record away from mattering.
        let insulinReturned = await insulinRecords ?? []
        let rescueReturned = await rescueRecords ?? []
        // Stated rather than left nil when nothing was truncated. Nil has to mean
        // "nobody said how far this reaches", because a baseline drawn from an
        // event series is the claim that the window was looked at and held
        // nothing — and a claim needs a stated extent. An untruncated query
        // covers exactly the window it asked for.
        let fetchedFrom = Date().addingTimeInterval(-lookback)
        let coveredFrom = FetchCoverage.bound(of: [
            FetchCoverage.bound(
                records: insulinReturned.count,
                dates: insulinReturned.compactMap(NightscoutDate.eventDate),
                asked: insulinCount
            ),
            FetchCoverage.bound(
                records: rescueReturned.count,
                dates: rescueReturned.compactMap(NightscoutDate.eventDate),
                asked: rescueCount
            ),
        ]) ?? fetchedFrom

        return TreatmentRibbons(
            insulin: insulin,
            carbsOnBoard: carbsOnBoard,
            rescue: rescue,
            coveredFrom: coveredFrom,
            carbsObserved: carbsObserved,
            insulinOnBoard: insulinOnBoard,
            insulinObserved: insulinObserved,
            carbsPerHour: carbsPerHour
        )
    }

    /// What each ribbon query asks for. Stated once because the number is also
    /// what tells a full answer from a truncated one.
    private static let insulinCount = 400
    private static let rescueCount = 100

    /// Grams out of a rescue note's text, for any surface holding one.
    static func rescueGrams(from notes: String) -> Double? {
        let range = NSRange(notes.startIndex ..< notes.endIndex, in: notes)
        guard let match = rescueCarbGrams.firstMatch(in: notes, range: range),
              let captured = Range(match.range(at: 1), in: notes) else { return nil }
        return Double(notes[captured])
    }

    private static func treatments(
        baseURL: String,
        token: String,
        eventTypes: [String],
        count: Int
    ) async -> [[String: Any]]? {
        var combined: [[String: Any]] = []
        var landed = false
        for eventType in eventTypes {
            let records = await getTreatments(baseURL: baseURL, token: token, count: count, items: [
                URLQueryItem(name: "find[eventType]", value: eventType),
            ])
            if let records {
                landed = true
                combined.append(contentsOf: records)
            }
        }
        return landed ? combined : nil
    }

    private static func getTreatments(
        baseURL: String,
        token: String,
        count: Int,
        items: [URLQueryItem]
    ) async -> [[String: Any]]? {
        var queryItems = items
        queryItems.append(URLQueryItem(name: "count", value: String(count)))
        guard let url = endpoint(baseURL: baseURL, path: "/api/v1/treatments.json", token: token, items: queryItems),
              let data = await get(url)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    struct Profile {
        var name: String?
        var timezone: TimeZone?
        var targetLowMgdl: Double?
        var targetHighMgdl: Double?
        var scheduledBasal: Double?

        /// `carbs_hr`, the profile's own carb absorption rate in grams per
        /// hour. The rescue ribbon's decay is anchored to it — see
        /// `RescueAbsorption`.
        var carbsPerHour: Double?

        /// The day's target segments, where the profile aims at a line rather
        /// than a band. Nil for a profile with a range — see `TargetSchedule`.
        var targetSchedule: TargetSchedule?
    }

    /// `count=1` because Nightscout answers with the profile's whole revision
    /// history otherwise — ten documents and 15 KB here for one that is wanted.
    static func profile(baseURL: String, token: String) async -> Profile? {
        guard let url = endpoint(baseURL: baseURL, path: "/api/v1/profile.json", token: token, items: [
            URLQueryItem(name: "count", value: "1"),
        ]), let data = await get(url) else { return nil }

        guard let documents = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let document = documents.first
        else { return nil }

        return parseProfile(document)
    }

    static func parseProfile(_ document: [String: Any]) -> Profile {
        var profile = Profile()
        profile.name = document["defaultProfile"] as? String

        let store = document["store"] as? [String: Any]
        let named = profile.name.flatMap { store?[$0] as? [String: Any] }
        guard let entry = named ?? store?.values.compactMap({ $0 as? [String: Any] }).first else {
            return profile
        }

        if let identifier = entry["timezone"] as? String {
            profile.timezone = TimeZone(identifier: identifier)
        }
        profile.targetLowMgdl = mgdl(segmentInForce(entry["target_low"]))
        profile.targetHighMgdl = mgdl(segmentInForce(entry["target_high"]))
        // Not converted: a basal rate is units per hour, not glucose.
        profile.scheduledBasal = segmentInForce(entry["basal"])
        // A single figure rather than a schedule, and written as a string by
        // some uploaders.
        profile.carbsPerHour = numeric(entry["carbs_hr"])
        profile.targetSchedule = TargetSchedule(
            low: segments(entry["target_low"]),
            high: segments(entry["target_high"])
        )
        return profile
    }

    /// Every segment of a profile value, as seconds since local midnight and
    /// the figure from then on. Glucose figures are converted the way
    /// `segmentInForce` converts them, since a site in mmol/L stores them that
    /// way.
    static func segments(_ raw: Any?) -> [(TimeInterval, Double)] {
        guard let segments = raw as? [[String: Any]] else { return [] }
        return segments.compactMap { segment in
            guard let value = numeric(segment["value"]),
                  let seconds = numeric(segment["timeAsSeconds"]),
                  let converted = mgdl(value)
            else { return nil }
            return (seconds, converted)
        }
    }

    /// Profile values are time-segmented across the day and the widget shows one
    /// of them, so this takes the segment running now rather than the first one
    /// written.
    static func segmentInForce(_ raw: Any?, now: Date = Date(), timezone: TimeZone = .current) -> Double? {
        guard let segments = raw as? [[String: Any]], !segments.isEmpty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let minutesNow = Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))

        let parsed = segments.compactMap { segment -> (minutes: Double, value: Double)? in
            guard let value = numeric(segment["value"]),
                  let seconds = numeric(segment["timeAsSeconds"])
            else { return nil }
            return (seconds / 60, value)
        }.sorted { $0.minutes < $1.minutes }

        guard !parsed.isEmpty else { return nil }
        // Before the first segment of the day the one still running is the last
        // of the previous day, which is the final entry rather than the first.
        return (parsed.last { $0.minutes <= minutesNow } ?? parsed[parsed.count - 1]).value
    }

    // MARK: - Helpers

    /// Nightscout writes some profile numbers as strings.
    private static func numeric(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// Sites configured in mmol/L store these in mmol/L, and no glucose target is
    /// ever set as low as 40 mg/dL, so the small numbers are the ones to convert.
    private static func mgdl(_ value: Any?) -> Double? {
        guard let raw = numeric(value), raw > 0 else { return nil }
        return raw < 40 ? raw * GlucoseConversion.mmolToMgDl : raw
    }

    private static func eventType(_ treatment: [String: Any]) -> String {
        treatment["eventType"] as? String ?? ""
    }

    private static func endpoint(baseURL: String, path: String, token: String, items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.path = path
        var queryItems = items
        if !token.isEmpty {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    /// GET only, and nil on anything that is not a 200. The token this runs with
    /// may be write-capable, so the method is stated rather than defaulted.
    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout

        do {
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            // Intentionally silent (extension-safe, no dependencies).
            return nil
        }
    }
}
