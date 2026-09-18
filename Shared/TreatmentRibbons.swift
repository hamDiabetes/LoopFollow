// LoopFollow
// TreatmentRibbons.swift

import Foundation

/// A single treatment plotted as ribbon thickness: a bolus in units, or a carb
/// entry in grams.
///
/// Point events rather than spans: the run a bolus belongs to is derived from
/// spacing rather than recorded at the source.
struct TreatmentEvent: Codable, Equatable, Hashable {
    /// When it was delivered or entered.
    let date: Date

    /// Units for insulin, grams for carbs. Always positive.
    let amount: Double

    init(date: Date, amount: Double) {
        self.date = date
        self.amount = amount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date.timeIntervalSince1970, forKey: .date)
        try container.encode(amount, forKey: .amount)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .date))
        amount = try container.decode(Double.self, forKey: .amount)
    }

    private enum CodingKeys: String, CodingKey {
        case date = "d", amount = "a"
    }
}

/// What the chart knows about a standing quantity at one moment — carbs on
/// board, insulin on board, anything the loop reports per cycle.
///
/// A confident zero is worse than a blank. A blank is obviously a blank.
///
/// Three states, not two: a figure, a figure that happens to be zero, and no
/// figure at all. A case rather than an optional, so that no caller can quietly
/// spell the difference `?? 0`.
enum OnBoardReading: Equatable {
    /// The figure the loop reported. Zero here is a reported zero.
    case known(Double)

    /// Nothing was published near enough to this moment to say.
    case unknown

    var value: Double? {
        switch self {
        case let .known(value): return value
        case .unknown: return nil
        }
    }
}

/// Carbs on board at one loop cycle, as the algorithm reported it.
///
/// Sampled rather than derived from the carb entries: the ribbon shows what the
/// loop believes, absorption and profile included, not what this chart could
/// recompute.
struct CarbsOnBoardSample: Codable, Equatable, Hashable {
    let date: Date

    /// Grams, as reported. Integers in practice.
    let grams: Double

    init(date: Date, grams: Double) {
        self.date = date
        self.grams = grams
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date.timeIntervalSince1970, forKey: .date)
        try container.encode(grams, forKey: .grams)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .date))
        grams = try container.decode(Double.self, forKey: .grams)
    }

    private enum CodingKeys: String, CodingKey {
        case date = "d", grams = "g"
    }
}

/// The retained carbs-on-board series, oldest first.
///
/// A rolling window rather than a fetch: `CarbsOnBoardStore` appends each cycle
/// as the app receives it, and a stretch the app missed is absent rather than
/// filled.
struct CarbsOnBoardHistory: Codable, Equatable, Hashable {
    let samples: [CarbsOnBoardSample]

    /// When the newest sample was published, not when the file was written.
    let updatedAt: Date

    init(samples: [CarbsOnBoardSample], updatedAt: Date) {
        self.samples = samples
        self.updatedAt = updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samples, forKey: .samples)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        samples = try container.decode([CarbsOnBoardSample].self, forKey: .samples)
        updatedAt = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .updatedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case samples = "s", updatedAt = "u"
    }
}

/// One stretch in which a series was actually being watched.
struct ObservedStretch: Codable, Equatable, Hashable {
    /// First moment observed, and the last. Both inclusive.
    let from: Date
    let through: Date

    init(from: Date, through: Date) {
        self.from = from
        self.through = through
    }

    func contains(_ moment: Date) -> Bool {
        moment >= from && moment <= through
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from.timeIntervalSince1970, forKey: .from)
        try container.encode(through.timeIntervalSince1970, forKey: .through)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .from))
        through = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .through))
    }

    private enum CodingKeys: String, CodingKey {
        case from = "f", through = "t"
    }
}

/// Where a series was watched, and the grid it was watched on.
///
/// Absence means different things inside and outside it. Inside, a slot with no
/// sample is a slot the loop reported nothing for, which for carbs on board is
/// zero; outside, it is a slot nobody was listening to. That is what lets a
/// series stop spelling out its zeros.
///
/// Several stretches rather than one span, because observation breaks: a pump
/// comms outage falls between two of them and is neither zero nor a held
/// figure.
///
/// `step` is not decoration: implying a zero only makes sense against a grid.
/// The producer states it; nothing here infers it.
///
/// **A grid and the samples it is read against must come from the same array.**
/// A grid built from a wider source has stretches that begin before the samples
/// do, and a moment inside such a stretch with nothing before it is answered as
/// a reported zero — a figure nobody published, from the mechanism built to stop
/// exactly that. The carb series did this for a while and was saved only by a
/// trim that happened to keep one sample from before the window: correct by luck
/// and correct by construction are the same green until something moves.
struct ObservedGrid: Codable, Equatable, Hashable {
    let stretches: [ObservedStretch]

    /// How long one sample speaks for: the spacing of the series this grid was
    /// built from, and nothing else's.
    ///
    /// **It is not one number with one meaning across the app**, which is why it
    /// is named for the series rather than for the chart. The app's own stores
    /// state the loop's publication interval; a pushed insulin series states its
    /// own sampling spacing, which is `n` slots and wider; a pushed carb series
    /// states the chart's slot spacing, because that is what its runs are
    /// counted in. A grid carrying a spacing from one of those and samples from
    /// another answers with a figure nobody published.
    let sampleSpacing: TimeInterval

    init(stretches: [ObservedStretch], sampleSpacing: TimeInterval) {
        self.stretches = stretches
        self.sampleSpacing = sampleSpacing
    }

    func stretch(containing moment: Date) -> ObservedStretch? {
        stretches.first { $0.contains(moment) }
    }

    private enum CodingKeys: String, CodingKey {
        case stretches = "w", sampleSpacing = "s"
    }
}

extension CarbsOnBoardHistory {
    /// How far apart the loop's figures arrive, near enough.
    ///
    /// **Eleven minutes, because one missed cycle must not break the series.**
    /// Measured over 30 hours and 383 cycles: the median gap is 299 seconds, the
    /// 90th percentile 307, and the six largest gaps are 593, 593, 595, 596, 601
    /// and 605 — every one of them a single missed cycle, which is two cadences
    /// end to end. Nothing in that window ran longer.
    ///
    /// **The plateau starts at 660 and the old eight minutes was below it.** At
    /// 480 seconds those six gaps split the day into seven stretches; at 660 it
    /// is one, and it stays one at 720, 780 and 900. Eleven minutes is the
    /// bottom of the plateau rather than its middle, deliberately: two missed
    /// cycles leave about 900 seconds and still break the series, which is what
    /// a break is for.
    ///
    /// The eight came from measuring only that the jitter cleared five minutes,
    /// and from a claim in this comment that a missed cycle leaves 615 seconds.
    /// It does not — it leaves 593 to 605 — and that wrong number is what made
    /// 480 look safe. A threshold measured against a figure nobody checked is
    /// the same defect as a threshold measured against nothing.
    ///
    /// **This interval is two facts under one name**: how long a stretch may be
    /// bridged, and how long a published figure is held before absence inside a
    /// stretch reads as a reported zero. They move together here on purpose. A
    /// threshold raised without the hold turns a bridged gap into a dip to zero,
    /// which states a figure nobody published — worse than the hole it closed.
    static let publicationInterval: TimeInterval = 11 * 60

    /// Where this series was watched, for the chart to read absence against.
    ///
    /// The app is the producer here, so it can say: a stretch runs while its
    /// samples arrive at the cadence the loop publishes at, and breaks where
    /// they stop. An app suspended for an hour leaves a hole, and the hole is a
    /// stretch nobody heard rather than an hour with nothing on board.
    func grid(step: TimeInterval = publicationInterval) -> ObservedGrid? {
        let ordered = samples.map(\.date).sorted()
        guard let first = ordered.first else { return nil }

        // A stretch runs its last sample's hold, not to its timestamp. A stretch
        // is read by asking whether a reading falls inside it, and a reading is
        // a CGM time: it never lands on a sample's second. Ending at the last
        // sample gives a run of one no width at all, and a run of one is what a
        // broken series is made of — so the lone samples this grid produced drew
        // at no reading time in the chart, which is the same defect fixed on the
        // pushed series and missed here.
        //
        // One second short of the next sample's slot, so the instant a stretch
        // ends on cannot be answered as a reported zero.
        let held = step - 1
        var stretches: [ObservedStretch] = []
        var from = first
        var previous = first
        for date in ordered.dropFirst() {
            if date.timeIntervalSince(previous) > step {
                stretches.append(ObservedStretch(from: from, through: previous.addingTimeInterval(held)))
                from = date
            }
            previous = date
        }
        stretches.append(ObservedStretch(from: from, through: previous.addingTimeInterval(held)))
        return ObservedGrid(stretches: stretches, sampleSpacing: step)
    }
}

/// Insulin on board at one loop cycle, as the algorithm reported it.
///
/// **Negative figures are clamped to zero here, and never dropped.** oref
/// reports a negative when less insulin is acting than the profile's basal
/// would have delivered — 87 of 2000 real samples on this site, down to
/// −0.17 U. That is a known quantity rather than a missing one, and the two are
/// different claims on the chart: a dropped sample draws as unknown, which says
/// nobody was listening, while what actually happened is that the loop looked
/// and found nothing acting. Zero is the honest floor for a ribbon whose
/// thickness is a magnitude.
///
/// Display-only, like everything else in this file. Nothing here reaches
/// dosing, alerting or anything written back to Nightscout.
struct InsulinOnBoardSample: Codable, Equatable, Hashable {
    let date: Date

    /// Units, clamped at zero.
    let units: Double

    init(date: Date, units: Double) {
        self.date = date
        self.units = max(0, units)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date.timeIntervalSince1970, forKey: .date)
        try container.encode(units, forKey: .units)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .date))
        units = max(0, try container.decode(Double.self, forKey: .units))
    }

    private enum CodingKeys: String, CodingKey {
        case date = "d", units = "u"
    }
}

/// How a store takes one more sample when it may not be the only writer.
///
/// **Adding, never replacing.** Two processes write these files now — the app on
/// its poll and the widget on its timeline run — and a read-modify-write from
/// two sides can put back a copy that lost whatever arrived in between. A merge
/// cannot: the worst a lost race costs is one sample that the next cycle adds
/// again, where a replace would truncate history and look exactly like the
/// sparse store this was built to end.
///
/// Nil when the sample is already there, so an unchanged file is not rewritten
/// and the widget is not reloaded for nothing.
enum OnBoardMerge {
    static func merging(_ stored: [CarbsOnBoardSample], with sample: CarbsOnBoardSample) -> [CarbsOnBoardSample]? {
        guard !stored.contains(where: { $0.date == sample.date }) else { return nil }
        return (stored + [sample]).sorted { $0.date < $1.date }
    }

    static func merging(_ stored: [InsulinOnBoardSample], with sample: InsulinOnBoardSample) -> [InsulinOnBoardSample]? {
        guard !stored.contains(where: { $0.date == sample.date }) else { return nil }
        return (stored + [sample]).sorted { $0.date < $1.date }
    }

    /// A window of samples in one merge.
    ///
    /// The app's first poll after hours away carries every cycle it missed, and
    /// folding those in one at a time would be a coordinated file write each —
    /// hundreds of them, against a file the widget writes to as well.
    ///
    /// Nil on nothing new, on the same terms as the single-sample merge: the
    /// caller reloads the widget on a write that happened, and a window that
    /// restates what is held is not one.
    static func merging(_ stored: [CarbsOnBoardSample], with samples: [CarbsOnBoardSample]) -> [CarbsOnBoardSample]? {
        guard let added = newSamples(samples, keyedBy: \.date, against: stored.map(\.date)) else { return nil }
        return (stored + added).sorted { $0.date < $1.date }
    }

    static func merging(_ stored: [InsulinOnBoardSample], with samples: [InsulinOnBoardSample]) -> [InsulinOnBoardSample]? {
        guard let added = newSamples(samples, keyedBy: \.date, against: stored.map(\.date)) else { return nil }
        return (stored + added).sorted { $0.date < $1.date }
    }

    /// What of an incoming window is not already held, first occurrence wins.
    ///
    /// Deduplicated against the window as well as against the store: Nightscout
    /// answers with records, not cycles, and a cycle republished under a second
    /// record would otherwise put two samples on one instant — which
    /// `ObservedGrid` reads as a zero-length spacing.
    private static func newSamples<Sample>(
        _ samples: [Sample],
        keyedBy date: KeyPath<Sample, Date>,
        against stored: [Date]
    ) -> [Sample]? {
        var seen = Set(stored)
        var added: [Sample] = []
        for sample in samples where seen.insert(sample[keyPath: date]).inserted {
            added.append(sample)
        }
        return added.isEmpty ? nil : added
    }
}

/// The retained insulin-on-board series, oldest first, with the scale it is
/// drawn against.
struct InsulinOnBoardHistory: Codable, Equatable, Hashable {
    let samples: [InsulinOnBoardSample]

    let updatedAt: Date

    /// How far apart the loop's figures arrive, near enough. Shared with the
    /// carb series, which comes off the same record.
    static var publicationInterval: TimeInterval { CarbsOnBoardHistory.publicationInterval }

    init(samples: [InsulinOnBoardSample], updatedAt: Date) {
        self.samples = samples
        self.updatedAt = updatedAt
    }

    /// Where this series was watched, on the same terms as the carb series.
    func grid(step: TimeInterval = publicationInterval) -> ObservedGrid? {
        CarbsOnBoardHistory(
            samples: samples.map { CarbsOnBoardSample(date: $0.date, grams: $0.units) },
            updatedAt: updatedAt
        ).grid(step: step)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(samples, forKey: .samples)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        samples = try container.decode([InsulinOnBoardSample].self, forKey: .samples)
        updatedAt = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .updatedAt))
    }

    private enum CodingKeys: String, CodingKey {
        // "t" and "d" were the total daily dose and its retained history, back
        // when the ribbon's scale came from the loop. Both are ignored on read.
        case samples = "s", updatedAt = "u"
    }
}

/// Which producer the insulin ribbon is drawn from.
///
/// Two producers reach this chart and only one of them sends insulin on board.
/// The app fetches it and stores it; a Live Activity push carries what the
/// relay sends, and the relay has no key for the series yet. Reading the absent
/// series and drawing nothing is how the ribbon disappeared from a lock screen.
///
/// **The distinction is nil against empty, and it is the whole of this type.**
/// Nil means this producer does not supply the series, so the older one — doses
/// as point events, totalled over a window — is what there is. Empty, or a
/// series of reported zeros, means the loop looked and found nothing acting,
/// and the honest drawing of that is nothing. Falling back there would answer a
/// person with no insulin on board by marking their doses instead, which is the
/// chart saying something false in place of saying nothing.
enum InsulinRibbonSource: Equatable {
    /// The loop's own insulin-on-board series.
    case onBoard

    /// Boluses as point events, from a producer that sends no insulin on board.
    case doses

    static func choose(insulinOnBoard: [InsulinOnBoardSample]?) -> InsulinRibbonSource {
        insulinOnBoard == nil ? .doses : .onBoard
    }
}

/// How much of the plot a quantity of insulin on board claims.
///
/// Two settings rather than a figure derived from the loop, because what a
/// thickness is measured against has to hold still: the loop's own total daily
/// dose moved 19.4 U to 27.3 U across one measured day, which redrew a stretch
/// already on screen at a different width with nothing behind it having
/// changed.
enum InsulinOnBoard {
    /// Units of insulin on board that draw at full height, and everything above
    /// it draws there too.
    ///
    /// **Set rather than derived.** It used to be a share of the loop's total
    /// daily dose, which sounded like it tracked the person and in practice
    /// tracked the hour: that figure moved 19.4 U to 27.3 U across one real day,
    /// so a sample already on screen was redrawn thicker or thinner later with
    /// nothing behind it having changed. A number somebody chose does not move,
    /// and it is the number they can see.
    static let defaultFullScaleUnits: Double = 4

    /// How much of the plot full height is.
    ///
    /// A quarter of the card was too much: at the old scale 0.7 U drew about
    /// three times the width of the glucose trace, and 3 U would have taken a
    /// quarter of the whole thing. At 12% and four units, 0.7 U is a shade
    /// thicker than the trace and 3 U is a ribbon rather than a wall.
    static let defaultHeightShare: Double = 0.12

    /// Fraction of full height, from zero to one. Above the cap it is one: a
    /// ribbon that stops growing says "at least this much", which is what a cap
    /// is for, and the figure beside the chart says the rest.
    static func share(of units: Double, fullScaleUnits: Double) -> Double {
        guard fullScaleUnits > 0 else { return 0 }
        return min(1, max(0, units / fullScaleUnits))
    }
}

/// The three treatment series drawn as variable-width ribbons over the glucose
/// line. The side carries the direction: insulin below because it lowers
/// glucose, carbs and rescue carbs above because they raise it.
///
/// Every series is separately optional, and the difference matters: nil is a
/// question that went unanswered, an empty array is an answer of nothing. They
/// are gathered by different requests over different windows, so one failing
/// says nothing about the other two.
struct TreatmentRibbons: Codable, Equatable, Hashable {
    /// Boluses and automatic microboluses.
    ///
    /// No longer what the blue ribbon is drawn from — that is
    /// `insulinOnBoard` — but still what says a dose happened at a moment, which
    /// is what the orphan markers stand in for when no reading covers it.
    let insulin: [TreatmentEvent]?

    /// What the loop reports as insulin on board, sampled per cycle.
    ///
    /// The ribbon tracks a standing quantity rather than marking deliveries: a
    /// dose is a moment, and what a caregiver is reading the chart for is how
    /// much is still acting.
    let insulinOnBoard: [InsulinOnBoardSample]?

    /// Where the insulin-on-board series was watched, on the same terms as
    /// `carbsObserved`.
    let insulinObserved: ObservedGrid?

    /// What the loop reports as carbs on board, sampled per cycle.
    let carbsOnBoard: [CarbsOnBoardSample]?

    /// Rescue carbs, which the loop never sees. What is left of one at any
    /// moment is modelled here and nowhere else.
    let rescue: [TreatmentEvent]?

    /// The oldest moment any of this describes, where that is known.
    ///
    /// A Live Activity push states one, because the relay drops ribbon history
    /// before it drops readings when a payload will not fit. Everything before
    /// it is unknown rather than quiet.
    ///
    /// Nil where nothing limits the coverage, which is every path that gathers
    /// the series itself.
    let coveredFrom: Date?

    /// Where the carbs-on-board series was being watched, on the paths that can
    /// say. Inside it an absent sample is a reported zero; outside it, unknown.
    ///
    /// **This is the carb series' own range and nothing else's.** `coveredFrom`
    /// above is window-level and comes off the treatment fetch, and device
    /// status coverage is the narrower of the two for the first day after a
    /// relay restart. Licensing implied zeros with the window bound would assert
    /// zero across a stretch this series never saw.
    ///
    /// Nil where the producer cannot state one, which is every path that
    /// gathers the series itself. There, absence stays unknown and the hold
    /// below governs.
    let carbsObserved: ObservedGrid?

    /// The profile's `carbs_hr`, which the rescue ribbon's decay is anchored to.
    ///
    /// Nil on any surface that cannot reach the profile — every Live Activity,
    /// since the push carries no profile document — and there the model falls
    /// back to `RescueAbsorption.fallbackGramsPerHour`. **Absent means nobody
    /// told us, not zero.** The consequence is worth stating: until a push
    /// carries the figure, a rescue entry absorbs at one rate on the widget and
    /// another on the lock screen.
    let carbsPerHour: Double?

    init(
        insulin: [TreatmentEvent]?,
        carbsOnBoard: [CarbsOnBoardSample]?,
        rescue: [TreatmentEvent]?,
        coveredFrom: Date? = nil,
        carbsObserved: ObservedGrid? = nil,
        insulinOnBoard: [InsulinOnBoardSample]? = nil,
        insulinObserved: ObservedGrid? = nil,
        carbsPerHour: Double? = nil
    ) {
        self.insulin = insulin
        self.carbsOnBoard = carbsOnBoard
        self.rescue = rescue
        self.coveredFrom = coveredFrom
        self.carbsObserved = carbsObserved
        self.insulinOnBoard = insulinOnBoard
        self.insulinObserved = insulinObserved
        self.carbsPerHour = carbsPerHour
    }

    /// Everything answered, and every answer nothing.
    static let empty = TreatmentRibbons(insulin: [], carbsOnBoard: [], rescue: [])

    /// Nothing to draw: no series has anything in it, whether because it was
    /// empty or because it never landed. A caller distinguishing a failure from
    /// a quiet day reads the series, not this.
    var isEmpty: Bool {
        (insulin?.isEmpty ?? true) && (carbsOnBoard?.isEmpty ?? true) && (rescue?.isEmpty ?? true)
            && (insulinOnBoard?.isEmpty ?? true)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(insulin, forKey: .insulin)
        try container.encodeIfPresent(carbsOnBoard, forKey: .carbsOnBoard)
        try container.encodeIfPresent(rescue, forKey: .rescue)
        try container.encodeIfPresent(coveredFrom?.timeIntervalSince1970, forKey: .coveredFrom)
        try container.encodeIfPresent(carbsObserved, forKey: .carbsObserved)
        try container.encodeIfPresent(carbsPerHour, forKey: .carbsPerHour)
        try container.encodeIfPresent(insulinOnBoard, forKey: .insulinOnBoard)
        try container.encodeIfPresent(insulinObserved, forKey: .insulinObserved)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        insulin = try container.decodeIfPresent([TreatmentEvent].self, forKey: .insulin)
        carbsOnBoard = try container.decodeIfPresent([CarbsOnBoardSample].self, forKey: .carbsOnBoard)
        rescue = try container.decodeIfPresent([TreatmentEvent].self, forKey: .rescue)
        coveredFrom = try container.decodeIfPresent(Double.self, forKey: .coveredFrom)
            .map { Date(timeIntervalSince1970: $0) }
        carbsObserved = try container.decodeIfPresent(ObservedGrid.self, forKey: .carbsObserved)
        carbsPerHour = try container.decodeIfPresent(Double.self, forKey: .carbsPerHour)
        insulinOnBoard = try container.decodeIfPresent([InsulinOnBoardSample].self, forKey: .insulinOnBoard)
        insulinObserved = try container.decodeIfPresent(ObservedGrid.self, forKey: .insulinObserved)
    }

    private enum CodingKeys: String, CodingKey {
        case insulin = "i", carbsOnBoard = "c", rescue = "r", coveredFrom = "f"
        case carbsObserved = "o"
        // "t" was the total daily dose, back when it was the ribbon's scale.
        case insulinOnBoard = "b", insulinObserved = "n"
        case carbsPerHour = "h"
    }
}

// MARK: - Rescue carb absorption

/// What this chart believes happens to a rescue carb, since nothing else
/// believes anything about it.
///
/// Rescue carbs are logged as Nightscout notes with no `carbs` field, which is
/// what keeps the loop from dosing for them. The cost of that safety property
/// is that no carbs-on-board figure ever comes back, so a ribbon width and a
/// hover value have to be modelled here.
///
/// **This estimate is display-only.** It must not reach dosing, alerting, or
/// anything written back to Nightscout. It exists to give a ribbon a thickness
/// and a readout a number.
enum RescueAbsorption {
    /// How long the grams take to count as fully on board. Rescue carbs are
    /// fast by definition, and a step change at the moment of entry would draw
    /// a wall rather than a ribbon.
    static let onset: TimeInterval = 8 * 60

    /// How fast carbs come off, where nobody has said.
    ///
    /// The profile's `carbs_hr` is the figure to use and this is what stands in
    /// when it is out of reach — which is every Live Activity, since the push
    /// carries no profile. Deliberately slower than this family's own 21 g/hr:
    /// a fallback that cleared carbs faster than the truth would draw a ribbon
    /// ending before the carbs did.
    static let fallbackGramsPerHour: Double = 15

    /// Multiplier on the published rate, for tuning the model against what is
    /// actually seen without touching the anchor it rides on.
    ///
    /// One, until somebody looks at it on a chart and says otherwise. The
    /// direction that needs watching is downward: the observed breakfast
    /// cleared 35 g in 39 minutes, about 54 g/hr against a published 21, so
    /// this model already errs long — which is the conservative direction for
    /// an estimate nothing can check.
    static let rateMultiplier: Double = 1.0

    /// Closer than this to the end and the entry is done. See `remaining`.
    static let endTolerance: TimeInterval = 1

    /// The longest a rescue entry is ever drawn for, used for windowing rather
    /// than by the model: how far back a fetch reaches, and how far forward a
    /// payload keeps an entry. A duration now depends on the amount, so there
    /// is no single figure the model could offer here.
    static let maxDuration: TimeInterval = 3 * 3600

    /// Kept as the windowing figure it always was for callers outside this
    /// file, which is all it was ever used for.
    static var duration: TimeInterval { maxDuration }

    /// How long one entry contributes anything at all.
    ///
    /// **Grams divided by a rate, not a constant.** The model this replaces gave
    /// every entry the same seventy minutes, so six grams and sixty cleared
    /// together, which is wrong at any pair of constants. The rate is the
    /// profile's own `carbs_hr` where the surface can reach it: a number the
    /// loop already publishes, which follows the person's settings without
    /// anyone maintaining a second copy.
    ///
    /// **This cannot be validated against the loop and never will be.** A rescue
    /// note carries no `carbs` field, so nothing downstream ever counts it —
    /// that is the safety property keeping it out of dosing, and the reason this
    /// stays a model rather than becoming a measurement.
    static func duration(ofGrams grams: Double, rate: Double?) -> TimeInterval {
        let perHour = (rate.map { $0 * rateMultiplier } ?? fallbackGramsPerHour * rateMultiplier)
        let usable = perHour > 0 ? perHour : fallbackGramsPerHour
        return onset + (max(0, grams) / usable) * 3600
    }

    /// Grams still on board from one entry, at one moment.
    static func remaining(of entry: TreatmentEvent, at moment: Date, rate: Double? = nil) -> Double {
        let elapsed = moment.timeIntervalSince(entry.date)
        guard elapsed >= 0 else { return 0 }
        if elapsed < onset {
            return entry.amount * (elapsed / onset)
        }
        let total = duration(ofGrams: entry.amount, rate: rate)
        // Stated rather than left to the arithmetic. A duration is a fraction
        // of an hour added to a date, and the round trip back out of `Date`
        // leaves a fraction of a nanosecond, so the last moment of absorption
        // computes as a ribbon 2e-10 grams thick — drawn, carrying an edge, and
        // counted as a treatment the chart could not place. A second is the
        // tolerance because the chart samples every five minutes; nothing here
        // can draw a distinction finer than that.
        guard elapsed < total - endTolerance else { return 0 }
        let decay = total - onset
        guard decay > 0 else { return 0 }
        return max(0, entry.amount * (1 - (elapsed - onset) / decay))
    }

    /// Grams on board across every entry still absorbing.
    ///
    /// Summed rather than taken from the most recent entry: rescue carbs arrive
    /// in batches minutes apart, so several are typically absorbing at once and
    /// the ribbon should show their combined weight.
    static func remaining(of entries: [TreatmentEvent], at moment: Date, rate: Double? = nil) -> Double {
        entries.reduce(0) { $0 + remaining(of: $1, at: moment, rate: rate) }
    }

    /// The batch an entry belongs to, as the entries around it that overlap in
    /// time.
    static func batch(containing entry: TreatmentEvent, in entries: [TreatmentEvent]) -> [TreatmentEvent] {
        let sorted = entries.sorted { $0.date < $1.date }
        guard let index = sorted.firstIndex(of: entry) else { return [entry] }

        var lower = index
        while lower > 0, sorted[lower].date.timeIntervalSince(sorted[lower - 1].date) <= batchGap {
            lower -= 1
        }
        var upper = index
        while upper < sorted.count - 1, sorted[upper + 1].date.timeIntervalSince(sorted[upper].date) <= batchGap {
            upper += 1
        }
        return Array(sorted[lower ... upper])
    }

    /// Longer than this between two entries and they are separate batches.
    ///
    /// The observed pattern is three entries four to five minutes apart, so ten
    /// minutes separates a pause within a batch from the end of one. Erring
    /// long merges two batches into one readout; erring short splits a batch
    /// the caregiver treated as a single decision.
    static let batchGap: TimeInterval = 10 * 60
}

// MARK: - Insulin runs

/// A stretch of boluses close enough together to read as one delivery.
///
/// The sketch asks for a hover that reports the amount at the touched point and
/// the total for the run it belongs to, because the loop often gives a lot of
/// small boluses in a row and the run is the thing worth seeing.
enum InsulinRuns {
    /// Longer than this between two boluses and the run has ended. Automatic
    /// microboluses land on the loop cycle, roughly every five minutes.
    static let gap: TimeInterval = 12 * 60

    /// Splits events into runs, oldest first. Events need not be sorted.
    static func split(_ events: [TreatmentEvent]) -> [[TreatmentEvent]] {
        let sorted = events.sorted { $0.date < $1.date }
        var runs: [[TreatmentEvent]] = []
        var current: [TreatmentEvent] = []
        for event in sorted {
            if let last = current.last, event.date.timeIntervalSince(last.date) > gap {
                runs.append(current)
                current = []
            }
            current.append(event)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Units delivered across a run.
    static func total(_ run: [TreatmentEvent]) -> Double {
        run.reduce(0) { $0 + $1.amount }
    }
}

// MARK: - Treatments no ribbon can carry

/// Which treatments fall where the chart has nothing to draw them on.
///
/// The ribbons are sampled at the readings, so a treatment contributes nothing
/// at all unless some reading lands where it would have thickened one. Those
/// are the ones a marker stands in for.
///
/// Each answer comes from the sampler that draws the series rather than from a
/// span restated here. Stated separately, the two disagreed over a single
/// instant and dropped a bolus between them: drawn nowhere, and marked nowhere
/// either. One authority is what stops that returning.
enum RibbonOrphans {
    /// Boluses with no reading inside the window they are counted over.
    static func insulin(_ events: [TreatmentEvent]?, readings: [Date], window: TimeInterval) -> [Date] {
        (events ?? [])
            .filter { $0.amount > 0 }
            .filter { event in
                !readings.contains { (RibbonSampler.insulin([event], at: $0, window: window) ?? 0) > 0 }
            }
            .map(\.date)
    }

    /// Rescue entries with no reading anywhere in their absorption.
    static func rescue(_ entries: [TreatmentEvent]?, readings: [Date], rate: Double? = nil) -> [Date] {
        (entries ?? [])
            .filter { $0.amount > 0 }
            .filter { entry in
                !readings.contains { (RibbonSampler.rescue([entry], at: $0, rate: rate) ?? 0) > 0 }
            }
            .map(\.date)
    }

    /// **Carbs on board gets no markers, and that is the point.**
    ///
    /// A marker says *a treatment happened here and the chart could not draw
    /// it*. Insulin and rescue are treatments: somebody gave a dose, at a
    /// moment. A carbs-on-board sample is not — it is an observation of a state
    /// the loop was already tracking, and the moment attached to it is when the
    /// loop looked, not when anything was eaten.
    ///
    /// Marking them turned observation gaps into events. In a sparse store it
    /// drew eleven markers across four hours in which nothing whatsoever
    /// happened, which is the chart stating something false — the one thing this
    /// feature exists to prevent, produced by the mechanism built to prevent it.
    ///
    /// What a gap in the carb series deserves is what it now gets: no ribbon,
    /// no baseline, and nothing claiming otherwise.
}

// MARK: - Where the chart knows a value

/// The stretches along which a series has a value to state, including zero.
///
/// A ribbon with no thickness draws nothing, so a stretch the loop reported as
/// zero and a stretch nobody watched are the same pixels — none. That is the
/// confusion this exists to end: a hairline says *the chart knows what was
/// happening here and it was nothing*, and an absence of one says *nobody was
/// listening*. Both are answers; only one of them is a measurement.
///
/// It is also the last thing on this chart that was being inferred rather than
/// drawn. Insulin comes from the loop's own figure against a scale somebody
/// set, carbs from its carbs on board, rescue decays at the profile's own
/// rate — and what is left is the difference between knowing zero
/// and not knowing, which the data already carried and nothing showed.
enum RibbonBaseline {
    /// Index ranges over the plotted readings where the series has a value.
    ///
    /// Broken where the value is unknown, and broken again where the readings
    /// themselves are — a baseline drawn across a sensor dropout would assert a
    /// continuity the glucose series denies, which is the rule the ribbons
    /// already follow.
    static func runs(known: [Bool], gapAfter: [Bool]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?

        for index in known.indices {
            if known[index], start == nil { start = index }
            guard let first = start else { continue }
            let ends = index == known.count - 1
                || !known[index + 1]
                || (index < gapAfter.count && gapAfter[index])
            guard ends else { continue }
            runs.append(first ... index)
            start = nil
        }
        return runs
    }
}

// MARK: - Sampling for the chart

/// Turns the three series into a thickness per sample time. The ribbons are
/// filled shapes, so they need a value everywhere the chart plots, not only
/// where a treatment happened.
enum RibbonSampler {
    /// Units delivered in the window ending at `moment`.
    ///
    /// A window rather than an instant: boluses are discrete and land between
    /// sample times, so sampling instantaneously would miss most of them and
    /// draw a ribbon of spikes separated by nothing.
    ///
    /// Nil for a series that never landed: insulin the widget could not fetch is
    /// not insulin that was not given.
    static func insulin(_ events: [TreatmentEvent]?, at moment: Date, window: TimeInterval) -> Double? {
        guard let events else { return nil }
        let start = moment.addingTimeInterval(-window)
        return events
            .filter { $0.date > start && $0.date <= moment }
            .reduce(0) { $0 + $1.amount }
    }

    /// Longer than this since the last published figure and the chart stops
    /// claiming one.
    ///
    /// The loop publishes every few minutes, so this is several missed cycles.
    /// It is the glucose line's own dropout rule, `WidgetChartView.maxGap`,
    /// restated for a series with a slower cadence: a ribbon carried across an
    /// outage is the same lie as a line drawn through one.
    static let carbsOnBoardMaxHold: TimeInterval = 20 * 60

    /// Carbs on board at `moment`.
    ///
    /// Held rather than interpolated. The loop publishes a figure per cycle and
    /// it is a step function between them; smoothing it would invent
    /// intermediate values the algorithm never reported.
    ///
    /// Two readings of an absent sample, and `observed` chooses between them.
    /// Inside a stretch the series was being watched, so nothing reported for a
    /// slot means the loop reported zero. Outside every stretch — or with no
    /// grid at all, which is every path that gathers the series itself — absence
    /// means nobody was listening.
    ///
    /// **A figure never leaves the stretch it was reported in.** The hold exists
    /// for a series with no stated grid, where the next cycle's absence is
    /// ambiguous. Where the grid is stated, carrying a figure past the end of
    /// observation claims the loop reported something it did not — and that end
    /// is usually the now line. Inside a stretch the hold is one slot, for the
    /// same reason: the slot after a sample is the series saying zero.
    ///
    /// One step is enough to compare against, and it is worth saying why, since
    /// two of us reasoned otherwise from this line. A stretch is built so that
    /// consecutive samples are at most a step apart, so inside one the elapsed
    /// time since the last sample is always under a step — except at exact
    /// equality, which needs a moment landing on the next sample's timestamp to
    /// the second. **What the comparison cannot mean here is an absence between
    /// samples**: that is the producer's grid, not the evaluation moment's, and
    /// the two coincide only on the payload path. On a producer that keeps every
    /// figure it heard, the stretch construction is what makes the question
    /// never arise.
    static func carbsOnBoard(
        _ samples: [CarbsOnBoardSample]?,
        at moment: Date,
        observed: ObservedGrid? = nil
    ) -> OnBoardReading {
        guard let samples else { return .unknown }

        func latest(notBefore earliest: Date?) -> CarbsOnBoardSample? {
            samples
                .filter { $0.date <= moment && $0.date >= (earliest ?? .distantPast) }
                .max(by: { $0.date < $1.date })
        }

        if let observed {
            guard let stretch = observed.stretch(containing: moment) else { return .unknown }
            guard let latest = latest(notBefore: stretch.from),
                  moment.timeIntervalSince(latest.date) < observed.sampleSpacing
            else { return .known(0) }
            return .known(latest.grams)
        }

        guard let latest = latest(notBefore: nil),
              moment.timeIntervalSince(latest.date) < carbsOnBoardMaxHold
        else { return .unknown }
        return .known(latest.grams)
    }

    /// Insulin on board at `moment`, on the same terms as carbs on board:
    /// held between cycles, zero where an observed stretch says the loop
    /// reported nothing, unknown where nobody was listening.
    static func insulinOnBoard(
        _ samples: [InsulinOnBoardSample]?,
        at moment: Date,
        observed: ObservedGrid? = nil
    ) -> OnBoardReading {
        carbsOnBoard(
            samples?.map { CarbsOnBoardSample(date: $0.date, grams: $0.units) },
            at: moment,
            observed: observed
        )
    }

    /// Estimated rescue grams on board at `moment`. Nil for a series that never
    /// landed, for the same reason as insulin — and more so here, since nothing
    /// else on the chart reports a rescue carb at all.
    static func rescue(_ entries: [TreatmentEvent]?, at moment: Date, rate: Double? = nil) -> Double? {
        guard let entries else { return nil }
        return RescueAbsorption.remaining(of: entries, at: moment, rate: rate)
    }
}
