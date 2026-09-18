// LoopFollow
// LAChart.swift

import Foundation

/// The treatment ribbons carried in a Live Activity push.
///
/// Bare tuples with no keys at all. Measured against a week of this family's
/// real records: short-key objects break even at exactly an average day's event
/// count and go over the relay's trim limit on an ordinary one, while tuples
/// leave the budget spare it needs on a busy one. A shape that only fits on a
/// quiet day is not one to send a lock screen chart through.
///
/// Every tuple starts with a slot index into the chart it arrives with, so it
/// costs three digits rather than ten and needs no anchor of its own. That
/// quantises an event to the five minutes the readings are already on, which is
/// the resolution the ribbon is drawn at anyway.
///
/// Insulin and rescue are point events: `[slot, total]`. Their spans are
/// recomputed on the device from a model that lives there, so a span in the
/// tuple would be the payload restating a constant — which is exactly what it
/// was, at about 140 bytes a day.
///
/// Carbs are `[slot, span, total]`, because a stretch is what the tuple is.
///
/// `total` is hundredths of a unit for insulin and whole grams for both carb
/// series. Two scales rather than one because a quarter unit of insulin is a
/// quarter of what a bolus ribbon is made of, while half a gram is not a pixel.
///
/// Carbs were briefly quantised to five grams, which compressed the runs
/// further — Trio republishes a decrementing figure every cycle, so runs of an
/// exact number are short. It was dropped: measured across thirteen days of
/// real records, the worst 24-hour window is 3811 bytes against a 3896-byte
/// limit without it, and no window in that span goes over. Overflow costs
/// ribbon history, oldest end first, and says so in `from`. Rounding a three
/// gram tail away costs the truth, silently, on every absorption.
///
/// What is sent is the events, never the widths. The absorption model lives on
/// the device, in `RescueAbsorption`, because the in-app chart has no relay in
/// front of it and a model on the relay would have to exist twice.
struct LARibbons: Codable, Hashable {
    /// Boluses and microboluses, as `[slot, hundredths of a unit]`.
    let insulin: [[Int]]

    /// Carbs on board as the loop published it, as `[slot, span, grams]`, one
    /// tuple per stretch it held the same figure. The slot after a stretch ends
    /// is where the series returns to zero, which is what stops a held sample
    /// from running to the edge of the chart.
    let carbs: [[Int]]

    /// Rescue entries, as `[slot, grams]`. How long one goes on contributing is
    /// `RescueAbsorption`'s to say, on the device.
    let rescue: [[Int]]

    /// Where the carb series was observed, as `[slot, span]` per stretch.
    ///
    /// Absence inside a stretch is zero; absence outside every stretch is
    /// unknown. Zero used to be implied everywhere, which made a loop nobody had
    /// heard from indistinguishable from one reporting nothing on board. Stating
    /// every zero fixed that and cost 83 bytes on the worst real day, because a
    /// decrementing figure breaks a zero stretch into pieces. Stating where the
    /// series was observed costs one tuple and says the same thing.
    ///
    /// A stretch breaks where the samples do, so a pump-comms outage falls
    /// outside one and reads as nobody knowing, which is what it is.
    let observed: [[Int]]?

    /// The oldest slot the ribbon data actually describes, where the sender had
    /// to trim it.
    ///
    /// The relay drops ribbon history before it touches readings when a payload
    /// will not fit, so a busy night can legitimately send a chart whose
    /// treatments describe only the recent part of it. Nil where nothing was
    /// dropped. Without this the trimmed stretch is indistinguishable from a
    /// stretch in which nothing happened, which is the one thing it must not
    /// look like.
    let coveredFrom: Int?

    /// Insulin travels in hundredths of a unit.
    static let insulinScale: Double = 100

    var isEmpty: Bool {
        insulin.isEmpty && carbs.isEmpty && rescue.isEmpty && (observed?.isEmpty ?? true)
    }

    private enum CodingKeys: String, CodingKey {
        case insulin = "i", carbs = "c", rescue = "r", observed = "o", coveredFrom = "f"
    }

    /// Reduce the three series to tuples against a chart's own grid.
    ///
    /// Carbs on board is run-length encoded against the quantised figure. The
    /// loop republishes a number that decrements every cycle while carbs
    /// absorb, so runs of the exact figure barely exist; runs of the figure the
    /// ribbon is actually drawn at do.
    init?(_ ribbons: TreatmentRibbons, anchor: Double, step: Double, slots: Int) {
        guard step > 0, slots > 0 else { return nil }

        func slot(_ date: Date) -> Int {
            Int(((date.timeIntervalSince1970 - anchor) / step).rounded())
        }
        func units(_ value: Double) -> Int {
            Int((value * Self.insulinScale).rounded())
        }
        func grams(_ value: Double) -> Int {
            Int(value.rounded())
        }
        // The newest reading is the last slot, and a bolus given after it — in
        // the minutes since the sensor last reported — rounds past the end. It
        // is the most recent thing that happened and the most worth seeing, so
        // it is pulled back onto the last slot rather than dropped. Further out
        // than one slot is a clock disagreeing with itself, and is dropped.
        func placed(_ date: Date) -> Int? {
            let index = slot(date)
            guard index <= slots else { return nil }
            return min(index, slots - 1)
        }

        let span = { (seconds: TimeInterval) in max(1, Int((seconds / step).rounded())) }

        insulin = (ribbons.insulin ?? [])
            .compactMap { event -> [Int]? in
                guard let index = placed(event.date), index >= 0 else { return nil }
                return [index, units(event.amount)]
            }

        // A rescue entry from before the window is still absorbing into it, and
        // the widget deliberately fetches back far enough to find one. Its slot
        // is negative and the device rebuilds the date from it unchanged, so the
        // ribbon starts part-absorbed at the left edge instead of appearing out
        // of nothing partway across.
        let rescueSpan = span(RescueAbsorption.duration)
        rescue = (ribbons.rescue ?? [])
            .compactMap { event -> [Int]? in
                guard let index = placed(event.date), index + rescueSpan > 0 else { return nil }
                return [index, grams(event.amount)]
            }

        // A reported zero is data. It used to be dropped as padding, on the
        // reasoning that zero is the ribbon's resting state and a run of it
        // never has to be said — but absence now means the loop was not heard
        // from, not that it said nothing was on board, and those are different
        // answers to the question the card is asked. A stretch of zero is one
        // tuple, so saying it costs almost nothing, and not saying it cost a
        // wrong number on the now line.
        //
        // The newest sample gets the same pull-back the point events get. The
        // loop cycles seconds after the reading the chart is anchored on, so
        // without it the freshest figure rounds past the end and is dropped.
        var runs: [[Int]] = []
        var seen: [[Int]] = []
        for sample in (ribbons.carbsOnBoard ?? []).sorted(by: { $0.date < $1.date }) {
            guard let index = placed(sample.date), index >= 0 else { continue }
            let onBoard = grams(sample.grams)
            guard onBoard >= 0 else { continue }

            if var stretch = seen.last, stretch[0] + stretch[1] >= index - 1 {
                stretch[1] = max(stretch[1], index - stretch[0])
                seen[seen.count - 1] = stretch
            } else {
                seen.append([index, 0])
            }

            // A published zero has to be able to displace a figure, not just
            // fail to add one. Two cycles land in one slot whenever the newest
            // is pulled back onto the last slot, and if the later of them
            // reports nothing on board while the earlier reported thirty grams,
            // skipping it leaves the earlier figure standing — a ribbon at the
            // leading edge saying carbs are on board beside a numeric tile
            // correctly saying they are not.
            //
            // It removes rather than overwrites, because zero is what a slot
            // with no run inside the observed range already means. Writing it
            // as a run would spend bytes restating it.
            guard onBoard > 0 else {
                if var covering = runs.last, covering[0] + covering[1] >= index {
                    if covering[0] >= index {
                        runs.removeLast()
                    } else {
                        covering[1] = index - covering[0] - 1
                        runs[runs.count - 1] = covering
                    }
                }
                continue
            }
            if var last = runs.last, last[2] == onBoard, last[0] + last[1] >= index - 1 {
                last[1] = max(last[1], index - last[0])
                runs[runs.count - 1] = last
            } else if var last = runs.last, last[0] == index {
                // Two cycles rounding into the same slot: the later figure is
                // the one the chart should show, and a run cannot start where
                // the previous one did.
                last[2] = onBoard
                runs[runs.count - 1] = last
            } else {
                runs.append([index, 0, onBoard])
            }
        }
        // The stretch ends at the last cycle. Reaching it to the now line is
        // parked rather than rejected — commit 2843f1f8 carries it, with a
        // threshold of one and a half slots measured against thirteen days of
        // this pump's records — and whether it should land is a question about
        // the loop's own output: does a reported carbs-on-board figure describe
        // an instant, or the interval until the next report? That is Justin's.
        //
        // What is settled, measured across the three bands the production data
        // falls into, is that the producer's bound and the consumer's guard are
        // not a seam. Sample dates are rebuilt from slot indices, so every age
        // the guard can ever see is a whole number of steps: an age of 180 s and
        // one of 449 s both arrive as exactly one step. The 300-540 s band
        // therefore cannot produce a different answer from the healthy one, and
        // any guard bound strictly between one and two steps behaves
        // identically. Only the comparison at exactly one step decides anything.
        //
        //   under 300 s, and 300-540 s  ->  one step  ->  the figure, or zero,
        //                                                 by that comparison
        //   540 s and over              ->  two steps ->  outside the stretch,
        //                                                 unknown, every variant
        carbs = runs
        observed = seen.isEmpty ? nil : seen

        // Nothing is dropped on this path: the app builds the payload from the
        // series it holds, over the chart it is building. The field exists for
        // the relay, which trims ribbon history to fit and has to say where what
        // it sent begins.
        coveredFrom = nil

        if insulin.isEmpty, carbs.isEmpty, rescue.isEmpty, seen.isEmpty { return nil }
    }

    /// Back to the series the chart draws.
    ///
    /// Insulin and rescue arrive as starts alone: both are point events whose
    /// span the device recomputes, so a span in the payload would be overriding
    /// the model rather than informing it.
    ///
    /// Carbs are the other way round. A run is one tuple on the wire and one
    /// sample per slot here, because the sampler stops holding a figure after
    /// `RibbonSampler.carbsOnBoardMaxHold` and reports `.unknown` — which is
    /// the right answer for a gap in the record and the wrong one inside a run
    /// that is still going. Left as one sample, a two-hour absorption would
    /// draw twenty minutes of ribbon and then nothing. The restatement costs
    /// nothing on the wire: the run is what was sent, and this is what it
    /// means.
    func series(anchor: Double, step: Double, carbsPerHour: Double? = nil) -> TreatmentRibbons {
        func date(_ slot: Int) -> Date {
            Date(timeIntervalSince1970: anchor + Double(slot) * step)
        }
        func units(_ raw: Int) -> Double { Double(raw) / Self.insulinScale }

        // Every slot a run covers, and nothing else. A zero here is one the
        // loop published; a slot no run covers is one nothing was heard about,
        // which the sampler reports as unknown once its hold expires.
        //
        // A zero was once synthesized one slot past every run, to stop the
        // chart holding the last figure out to the edge of the plot. It landed
        // on the now line on most pushes and drew a reported zero there while
        // carbs were on board. The hold already ends a run that nothing
        // follows, and it ends it as unknown, which is what an absence of
        // samples actually means.
        // Only the figures. Where the series was watched travels separately, as
        // the grid below, and a slot inside it with no sample is the loop
        // reporting zero — stated once, by the grid, rather than spelled into
        // every slot here as well.
        var bySlot: [Int: Double] = [:]
        let runs = carbs.filter { $0.count == 3 && $0[1] >= 0 }.sorted { $0[0] < $1[0] }
        for run in runs {
            let grams = Double(run[2])
            for slot in run[0] ... (run[0] + run[1]) {
                bySlot[slot] = grams
            }
        }
        let samples = bySlot.map { CarbsOnBoardSample(date: date($0.key), grams: $0.value) }

        // The stretches, as moments, with the grid they were sampled on. The
        // step is not decoration: implying a zero only means anything against a
        // spacing, and stating it is the producer's job rather than the
        // consumer's to guess.
        let grid = observed.map { stretches in
            ObservedGrid(
                stretches: stretches.compactMap { stretch in
                    guard stretch.count == 2, stretch[1] >= 0 else { return nil }
                    // Through the end of the last slot it covers rather than to
                    // that slot's instant. Carb runs on this wire are one slot
                    // wide as the ordinary case — the loop decrements carbs on
                    // board almost every cycle, so runs never merge — and a
                    // one-slot stretch ending at its own timestamp has no width
                    // and answers no reading.
                    return ObservedStretch(
                        from: date(stretch[0]),
                        through: date(stretch[0] + stretch[1]).addingTimeInterval(step - 1)
                    )
                },
                sampleSpacing: step
            )
        }

        return TreatmentRibbons(
            insulin: insulin.compactMap { tuple in
                guard tuple.count == 2 else { return nil }
                return TreatmentEvent(date: date(tuple[0]), amount: units(tuple[1]))
            },
            carbsOnBoard: samples.sorted { $0.date < $1.date },
            rescue: rescue.compactMap { tuple in
                guard tuple.count == 2 else { return nil }
                return TreatmentEvent(date: date(tuple[0]), amount: Double(tuple[1]))
            },
            coveredFrom: coveredFrom.map { date($0) },
            carbsObserved: grid,
            carbsPerHour: carbsPerHour
        )
    }
}

/// The glucose history and forecast carried in a Live Activity push.
///
/// The Live Activity cannot read the App Group chart cache the widget uses: the
/// app writes that file, and the app being asleep is the reason a relay exists
/// at all. So the readings travel in the payload, and this is the shape they
/// arrive in.
///
/// Slotted rather than listed. Readings are already on a five-minute grid, so
/// an anchor, a step and one value per slot costs a fraction of what a
/// timestamp per point would, and the whole payload has 4KB to live in.
///
/// A slot with no reading is nil. It is never omitted and never filled in: the
/// chart splits its line at a twenty-minute gap, and a sensor outage arriving
/// as adjacent readings would draw as an unbroken trace across readings that
/// were never taken.
/// Insulin on board over the chart's own grid, sampled rather than per slot.
///
/// ```
/// { s: <slot the series starts at>, n: <slots between samples>, v: [tenths | null, …] }
/// ```
///
/// **`n` is the spacing and it is on the wire on purpose.** It is three slots
/// today, which is fifteen minutes only because the grid's step is five. Reading
/// it as a fixed number of minutes, or routing this series through a constant
/// meant for a different producer, puts every sample further apart than that
/// constant allows: each one becomes a stretch of no width, and a stretch of no
/// width is drawn only where a reading falls on a sample's timestamp to the
/// second. The series then disappears entirely. That is not a hypothetical —
/// it is the failure this series was written to fix, and it would arrive
/// wearing its own name.
///
/// **`s` is the coverage bound as well as the start.** Nothing is claimed before
/// it, so nothing is drawn there — not a zero.
///
/// **A null is a gap and never a floor.** It means either that nothing had been
/// published for that slot yet or that the newest value was more than twenty
/// minutes stale, and both mean the loop was not heard from. Drawing zero across
/// them would put a flat line through an outage, which is a confident number
/// where there is none.
struct LAIob: Codable, Hashable {
    /// The slot the first sample sits on, and the bound before which nothing is
    /// claimed.
    let s: Int

    /// Slots between samples.
    let n: Int

    /// Tenths of a unit, or null for a slot nothing is known about.
    let v: [Int?]

    /// Tenths, because 0.1 U is already finer than a pixel at phone width.
    static let scale: Double = 10

    /// The series as the chart draws it, with the grid that says where it was
    /// watched.
    ///
    /// The grid's step is this series' own spacing — `n` slots — so consecutive
    /// samples belong to one stretch, and a run of nulls breaks it. Samples are
    /// placed at their slot's moment and nothing is interpolated between them:
    /// insulin on board is a decay curve, so the chart drawing between two
    /// samples is following a shape the loop already published rather than
    /// inventing one.
    ///
    /// **A stretch runs a sample's whole hold, not to its last timestamp.** A
    /// stretch is read by asking whether a reading falls inside it, and a
    /// reading is a CGM time: it never lands on a sample's second. Ending a
    /// stretch at its last sample therefore gives a run of one no width at all
    /// and it answers nothing — so `[80, null, 45]` drew not value-gap-value but
    /// an empty chart, and so did a series of a single sample. That is the
    /// failure this whole series was written to fix, arriving from the other
    /// direction, and it bites hardest during an outage, which is when nulls
    /// appear and when the chart is being read hardest.
    ///
    /// **The hold is additive, not total.** The relay carries the newest figure
    /// forward for twenty minutes of its own before it emits a null, so a value
    /// on this wire may already be up to that old when it arrives, and this tail
    /// adds a spacing on top: about thirty-five minutes at three slots, over
    /// which a figure can be presented as current with nothing on the chart
    /// saying so. Inside a healthy cycle none of that is reachable — the next
    /// sample lands first. It is reachable only in the first half hour of an
    /// outage, which is when the chart is read hardest. If that sum wants
    /// shrinking, the carry-forward is the part to shrink: this tail is the
    /// series' own resolution and cannot go below it without the gaps coming
    /// back.
    ///
    /// The tail is exactly one spacing because that is the hold the sampler
    /// applies: past it, a moment still inside the stretch is answered as a
    /// reported zero. It is the leading edge that this also decides — the newest
    /// sample is now drawn for the spacing after it rather than vanishing at its
    /// own timestamp — and that is the same hold every other sample in the
    /// series already gets. A newest sample held is stale by a known amount; a
    /// newest sample undrawn is the defect.
    func series(anchor: Double, step: Double) -> (samples: [InsulinOnBoardSample], observed: ObservedGrid?, coveredFrom: Date)? {
        guard n > 0, step > 0, !v.isEmpty else { return nil }

        let spacing = Double(n) * step
        // One second short of the next sample's slot, so the instant a stretch
        // ends on cannot be answered as a reported zero. Below every clock this
        // chart reads from, and stated rather than left to a rounding.
        let held = spacing - 1
        var samples: [InsulinOnBoardSample] = []
        var stretches: [ObservedStretch] = []
        var runStart: Date?
        var runEnd: Date?

        for (index, tenths) in v.enumerated() {
            let date = Date(timeIntervalSince1970: anchor + Double(s + index * n) * step)
            guard let tenths else {
                if let from = runStart, let through = runEnd {
                    stretches.append(ObservedStretch(from: from, through: through.addingTimeInterval(held)))
                }
                runStart = nil
                runEnd = nil
                continue
            }
            samples.append(InsulinOnBoardSample(date: date, units: Double(tenths) / Self.scale))
            if runStart == nil { runStart = date }
            runEnd = date
        }
        if let from = runStart, let through = runEnd {
            stretches.append(ObservedStretch(from: from, through: through.addingTimeInterval(held)))
        }

        guard !samples.isEmpty else { return nil }
        return (
            samples,
            ObservedGrid(stretches: stretches, sampleSpacing: spacing),
            Date(timeIntervalSince1970: anchor + Double(s) * step)
        )
    }
}

struct LAChart: Codable, Hashable {
    /// Epoch seconds of slot zero.
    let anchor: Double

    /// Seconds between slots.
    let step: Double

    /// mg/dL per slot, oldest first, nil where no reading was taken.
    let values: [Int?]

    /// Epoch seconds of the loop cycle the forecast runs forward from, which is
    /// not when the push was built.
    let predictionAnchor: Double?

    /// The spread across the curves the loop published, as one low and one high
    /// per sample. The chart's only use for the curves is this envelope, so the
    /// relay computes it rather than sending four curves to have them reduced
    /// on arrival. Equal low and high is a forecast with no width, which the
    /// chart already draws as a line rather than a cone.
    let low: [Int]?
    let high: [Int]?

    /// Insulin, carbs and rescue carbs, drawn as ribbons over the readings.
    /// Optional throughout: a producer that does not gather them sends none,
    /// and a card built before they existed decodes without them.
    let ribbons: LARibbons?

    /// Insulin on board over the recent hours. Absent from a producer that does
    /// not send it, and also from one that does when nothing at all is known —
    /// see `insulinOnBoard` for what the chart makes of that.
    let iob: LAIob?

    /// The target the readings were measured against, as `[slot, low, high]`
    /// tuples, one per change and always including slot zero. Read as the newest
    /// tuple at or before a slot: most slots carry none, which is the saving.
    let target: [[Int]]?

    /// The readings, in the form the chart draws.
    ///
    /// Timestamps are rebuilt from the slot index, so a gap stays a gap: the
    /// points either side of it are the full interval apart and nothing is
    /// invented in between.
    var series: GlucoseChartSeries? {
        let points = values.enumerated().compactMap { index, value -> GlucoseChartPoint? in
            guard let value else { return nil }
            return GlucoseChartPoint(
                value: Double(value),
                date: Date(timeIntervalSince1970: anchor + Double(index) * step)
            )
        }
        guard let newest = points.last else { return nil }
        return GlucoseChartSeries(points: points, updatedAt: newest.date)
    }

    /// The forecast, rebuilt as the two curves whose per-index spread is the
    /// envelope that was sent. `bands(upTo:)` takes the minimum and maximum
    /// across curves, so it returns exactly the low and high it was given.
    var prediction: GlucosePrediction? {
        guard let predictionAnchor, let low, let high, low.count == high.count, low.count > 1 else {
            return nil
        }
        return GlucosePrediction(
            curves: ["low": low.map(Double.init), "high": high.map(Double.init)],
            source: .openAPS,
            anchor: Date(timeIntervalSince1970: predictionAnchor),
            updatedAt: Date(timeIntervalSince1970: predictionAnchor)
        )
    }

    /// The insulin-on-board series and the grid it was watched on, or nil where
    /// the push carried none.
    ///
    /// **Nil has two causes on this wire and they draw the same**: a producer
    /// that does not send the series at all, and one that does but had nothing
    /// to say about the whole span — the relay drops the field when every sample
    /// would be null. Both take the dose fallback, which is the older ribbon
    /// rather than a degraded one, and neither draws a zero. The distinction
    /// would matter if the two deserved different drawings; they do not, because
    /// a chart that cannot say how much insulin is acting should show what it
    /// does know, which is when it was given.
    var insulinOnBoard: (samples: [InsulinOnBoardSample], observed: ObservedGrid?, coveredFrom: Date)? {
        iob?.series(anchor: anchor, step: step)
    }

    /// The target, as the steps the chart draws.
    ///
    /// Read as the newest tuple at or before each slot, which is how the wire
    /// states it: one tuple per change, always including slot zero, so most
    /// slots carry none.
    ///
    /// A tuple whose low and high differ is a band, and this chart draws a line,
    /// so a profile aiming at a range produces no target here — the same answer
    /// the widget gives from the profile itself, rather than a line down the
    /// middle of a range nobody set.
    var targetSeries: TargetSeries? {
        guard let target, !target.isEmpty else { return nil }
        var steps: [TargetSeries.Step] = []
        for tuple in target {
            guard tuple.count == 3 else { continue }
            guard tuple[1] == tuple[2] else { return nil }
            steps.append(TargetSeries.Step(
                date: Date(timeIntervalSince1970: anchor + Double(tuple[0]) * step),
                mgdl: Double(tuple[1])
            ))
        }
        return steps.isEmpty ? nil : TargetSeries(steps: steps)
    }

    /// The treatment series, back in the form the chart draws. Nil when the push
    /// carried none, which is a chart with no ribbons rather than three empty
    /// ones.
    /// `carbsPerHour` comes from the snapshot beside the chart rather than from
    /// this payload: it is the profile's absorption rate, which the rescue
    /// ribbon's decay is anchored to and which the ribbons themselves never
    /// carried. **Absent stays absent** — nil falls through to
    /// `RescueAbsorption`'s own fallback rather than being replaced here, so a
    /// profile that says nothing and a profile that says 15 stay different
    /// facts.
    func treatmentRibbons(carbsPerHour: Double? = nil) -> TreatmentRibbons? {
        let onBoard = insulinOnBoard
        guard let ribbons, !ribbons.isEmpty else {
            // Insulin on board with no treatments at all is a real payload: a
            // quiet span still carries a decaying figure. It draws the blue
            // ribbon and nothing else.
            guard let onBoard else { return nil }
            return TreatmentRibbons(
                insulin: nil,
                carbsOnBoard: nil,
                rescue: nil,
                coveredFrom: onBoard.coveredFrom,
                insulinOnBoard: onBoard.samples,
                insulinObserved: onBoard.observed,
                carbsPerHour: carbsPerHour
            )
        }
        let series = ribbons.series(anchor: anchor, step: step, carbsPerHour: carbsPerHour)
        guard let onBoard else { return series }
        return TreatmentRibbons(
            insulin: series.insulin,
            carbsOnBoard: series.carbsOnBoard,
            rescue: series.rescue,
            coveredFrom: series.coveredFrom,
            carbsObserved: series.carbsObserved,
            insulinOnBoard: onBoard.samples,
            insulinObserved: onBoard.observed,
            carbsPerHour: carbsPerHour ?? series.carbsPerHour
        )
    }

    /// The moment the newest reading in this chart was taken, which is what the
    /// chart measures its window back from.
    var newestReadingAt: Date? {
        guard let lastIndex = values.lastIndex(where: { $0 != nil }) else { return nil }
        return Date(timeIntervalSince1970: anchor + Double(lastIndex) * step)
    }

    /// Spacing the readings and the forecast are both published at.
    static let standardStep: TimeInterval = 300

    /// Build from what the app has cached, for the updates the app sends itself.
    ///
    /// The relay is not the only writer: with it switched off the app drives its
    /// own Live Activity, and without this that path would send no chart and the
    /// lock screen would lose its background. Slotted the same way the relay
    /// does it, anchored on the newest reading so that accumulated drift is
    /// spent on the oldest ones rather than on the readings being acted on.
    init?(
        series: GlucoseChartSeries?,
        prediction: GlucosePrediction?,
        ribbons: TreatmentRibbons? = nil,
        window: TimeInterval
    ) {
        guard let series, let newest = series.points.last else { return nil }

        let step = Self.standardStep
        let cutoff = newest.date.addingTimeInterval(-window)
        let drawn = series.points.filter { $0.date >= cutoff }
        guard let oldest = drawn.first else { return nil }

        let slots = Int(((newest.date.timeIntervalSince1970 - oldest.date.timeIntervalSince1970) / step).rounded()) + 1
        let anchorTime = newest.date.timeIntervalSince1970 - Double(slots - 1) * step

        var slotted = [Int?](repeating: nil, count: slots)
        var placed = [TimeInterval?](repeating: nil, count: slots)
        for point in drawn {
            let index = Int(((point.date.timeIntervalSince1970 - anchorTime) / step).rounded())
            guard index >= 0, index < slots else { continue }
            let slotTime = anchorTime + Double(index) * step
            if let existing = placed[index],
               abs(point.date.timeIntervalSince1970 - slotTime) >= abs(existing - slotTime)
            {
                continue
            }
            slotted[index] = Int(point.value.rounded())
            placed[index] = point.date.timeIntervalSince1970
        }

        anchor = anchorTime
        self.step = step
        values = slotted
        self.ribbons = ribbons.flatMap { LARibbons($0, anchor: anchorTime, step: step, slots: slots) }
        // The app's own producer sends neither: insulin on board and the target
        // come from the relay, which has the retained history and the profile.
        // A payload without them takes the dose fallback and draws no target,
        // which is what this path did before they existed.
        iob = nil
        target = nil

        // Reduced to the same envelope the relay sends, so both producers put
        // the identical shape on screen rather than two that drift apart.
        let bands = prediction.map { $0.bands(upTo: $0.anchor.addingTimeInterval(window)) } ?? []
        if bands.count > 1, let predictionSource = prediction {
            predictionAnchor = predictionSource.anchor.timeIntervalSince1970
            low = bands.map { Int($0.low.rounded()) }
            high = bands.map { Int($0.high.rounded()) }
        } else {
            predictionAnchor = nil
            low = nil
            high = nil
        }
    }
}
