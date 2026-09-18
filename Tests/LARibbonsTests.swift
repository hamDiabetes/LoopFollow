// LoopFollow
// LARibbonsTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// The ribbon payload is the only part of the chart that is encoded twice — once
/// by the relay and once by the app — and it had never been run at all. These
/// are the round trips: what goes in comes back at the moment it happened, and
/// the events most worth seeing are not the ones the grid throws away.
struct LARibbonsTests {
    let anchor: Double = 1_757_000_000
    let step: Double = 300
    let slots = 288

    private func at(_ slot: Double) -> Date {
        Date(timeIntervalSince1970: anchor + slot * step)
    }

    private func encoded(
        insulin: [TreatmentEvent] = [],
        carbsOnBoard: [CarbsOnBoardSample] = [],
        rescue: [TreatmentEvent] = []
    ) -> LARibbons? {
        LARibbons(
            TreatmentRibbons(insulin: insulin, carbsOnBoard: carbsOnBoard, rescue: rescue),
            anchor: anchor,
            step: step,
            slots: slots
        )
    }

    @Test func aBolusComesBackAtTheMomentItWasGiven() throws {
        let given = at(40)
        let ribbons = try #require(encoded(insulin: [TreatmentEvent(date: given, amount: 1.25)]))
        let back = ribbons.series(anchor: anchor, step: step)

        let boluses = back.insulin ?? []
        #expect(boluses.count == 1)
        #expect(boluses[0].date == given)
        #expect(boluses[0].amount == 1.25)
    }

    /// The last slot is the newest reading, and a bolus given in the minutes
    /// since the sensor reported rounds past it. Dropping it loses the most
    /// recent thing that happened — and on the chart a caregiver is reading
    /// because something is happening now.
    @Test func aBolusGivenAfterTheNewestReadingSurvives() throws {
        let ribbons = try #require(encoded(insulin: [
            TreatmentEvent(date: at(Double(slots - 1) + 0.8), amount: 0.4),
        ]))

        #expect(ribbons.insulin.count == 1)
        #expect(ribbons.insulin[0][0] == slots - 1)
        #expect((ribbons.series(anchor: anchor, step: step).insulin ?? [])[0].amount == 0.4)
    }

    /// Past one slot it is not a bolus between readings, it is two clocks
    /// disagreeing, and putting it on the chart's edge would be inventing a
    /// position for it.
    @Test func anEventFurtherAheadThanOneSlotIsDropped() {
        #expect(encoded(insulin: [TreatmentEvent(date: at(Double(slots) + 2), amount: 0.4)]) == nil)
    }

    /// The widget fetches rescue entries from before the window precisely
    /// because they are still absorbing into it. Rejecting them here made the
    /// two surfaces disagree about the same records.
    @Test func aRescueEntryStillAbsorbingIntoTheWindowSurvives() throws {
        let entered = at(-4)
        let ribbons = try #require(encoded(rescue: [TreatmentEvent(date: entered, amount: 16)]))

        #expect(ribbons.rescue.count == 1)
        #expect(ribbons.rescue[0][0] == -4)
        let back = ribbons.series(anchor: anchor, step: step)
        let entries = back.rescue ?? []
        #expect(entries[0].date == entered)
        #expect(entries[0].amount == 16)
        #expect(RescueAbsorption.remaining(of: entries, at: at(0)) > 0)
    }

    @Test func aRescueEntryAlreadyFullyAbsorbedIsDropped() {
        let spans = (RescueAbsorption.duration / step).rounded()
        #expect(encoded(rescue: [TreatmentEvent(date: at(-spans - 2), amount: 16)]) == nil)
    }

    /// Point events carry no span: the device recomputes it, so sending one
    /// would be the payload restating a constant.
    @Test func pointEventsCarryNoSpan() throws {
        let ribbons = try #require(encoded(
            insulin: [TreatmentEvent(date: at(10), amount: 0.5)],
            carbsOnBoard: [CarbsOnBoardSample(date: at(10), grams: 20)],
            rescue: [TreatmentEvent(date: at(12), amount: 15)]
        ))

        #expect(ribbons.insulin[0].count == 2)
        #expect(ribbons.rescue[0].count == 2)
        #expect(ribbons.carbs[0].count == 3)
    }

    /// What the run-length encoding does and does not buy, stated so nobody
    /// re-derives a saving that is not there. A figure the loop holds is one
    /// tuple however long it holds; a figure that changes every cycle is a
    /// tuple a cycle. Carbs travel as exact grams because, measured across
    /// thirteen days of real records, the worst 24-hour window is 3811 bytes
    /// against a 3896-byte limit that way — and rounding a three gram tail away
    /// to buy margin costs the truth on every absorption.
    @Test func runsCompressAHeldFigureAndNothingElse() throws {
        var held: [CarbsOnBoardSample] = []
        for index in 0 ..< 30 {
            held.append(CarbsOnBoardSample(date: at(Double(index)), grams: 40))
        }
        #expect(try #require(encoded(carbsOnBoard: held)).carbs.count == 1)

        var changing: [CarbsOnBoardSample] = []
        for index in 0 ..< 30 {
            changing.append(CarbsOnBoardSample(date: at(Double(index)), grams: 40 - Double(index)))
        }
        #expect(try #require(encoded(carbsOnBoard: changing)).carbs.count == 30)
    }

    /// The exact figure comes back exactly. Nothing between the loop and the
    /// ribbon rounds it.
    @Test func carbsComeBackExactly() throws {
        var samples: [CarbsOnBoardSample] = []
        for (index, grams) in [22.0, 17.0, 9.0, 3.0].enumerated() {
            samples.append(CarbsOnBoardSample(date: at(Double(index) * 4), grams: grams))
        }
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        let back = ribbons.series(anchor: anchor, step: step)

        for sample in samples {
            #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: sample.date, observed: back.carbsObserved) == .known(sample.grams))
        }
    }

    /// The now line is the number a caregiver's eye goes to first, and it was
    /// wrong on most pushes. A zero was synthesized one slot past every run to
    /// stop the chart holding its last figure out to the plot edge; the loop
    /// cycles seconds after each reading, so at a reading-triggered push the
    /// newest carb sample is the previous cycle and the synthesized zero landed
    /// exactly on now. Thirty grams on board, and the ribbon tapered to nothing
    /// at the moment being read.
    @Test func theNowSlotReportsWhatTheLoopSaidRatherThanASynthesizedZero() throws {
        var samples: [CarbsOnBoardSample] = []
        for index in 0 ... (slots - 2) {
            samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 30))
        }
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        let back = ribbons.series(anchor: anchor, step: step)

        // Not a zero. That is the whole of it: the loop had not reported for
        // this slot yet, so the honest answers are the figure it last gave or
        // nothing at all — and with the grid stated it is nothing at all, one
        // cycle behind, until the next report lands. What it must never be is a
        // confident zero while thirty grams are on board.
        let now = RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(slots - 1)), observed: back.carbsObserved)
        #expect(now != .known(0), "the now slot came back \(now)")
        #expect(now == .unknown, "the now slot came back \(now)")

        // And the slot the loop did report for still says what it said.
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(slots - 2)), observed: back.carbsObserved) == .known(30))
    }

    /// The stretch ends where the reports end, and nothing stretches it to meet
    /// the now line.
    ///
    /// Extending it was tried and measured. The consumer holds a figure inside a
    /// stretch for strictly less than one step, and the interval from a loop
    /// cycle to the reading that follows it has a dirty tail: median 288 s
    /// against a 300 s step, but p99 is 588 s and the worst in thirteen days is
    /// 1787 s. A stretch reaching the now line with the newest figure a step or
    /// more old reports zero carbs on board — and a cycle runs late exactly when
    /// the loop is struggling, which is when the card is being read. There is no
    /// encoding of "observed through now" that does not assert something the
    /// loop never said.
    @Test func theStretchEndsWhereTheReportsEnd() throws {
        var samples: [CarbsOnBoardSample] = []
        for index in 0 ... (slots - 6) {
            samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 30))
        }
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        let back = ribbons.series(anchor: anchor, step: step)

        let stretch = try #require(back.carbsObserved?.stretches.last)
        // Through the end of the slot it covers rather than to that slot's
        // instant, so a run of one slot — which is the ordinary case on this
        // wire — has width to answer a reading with.
        #expect(stretch.through == at(Double(slots - 6)).addingTimeInterval(step - 1))

        let now = RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(slots - 1)), observed: back.carbsObserved)
        #expect(now == .unknown, "the now slot came back \(now)")

        // Two slots past the last report, which is inside the twenty-minute
        // hold: the grid has to be the reason for the silence. The assertion
        // above cannot tell — five slots out, the hold has expired too, so it
        // reads unknown with the grid disabled entirely. In this file `.unknown`
        // is also what an absent series, an empty one and an expired one
        // return, so an assertion whose fixture does not reach is decoration.
        let insideTheHold = at(Double(slots - 4))
        #expect(insideTheHold.timeIntervalSince(at(Double(slots - 6))) < RibbonSampler.carbsOnBoardMaxHold)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: insideTheHold) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: insideTheHold, observed: back.carbsObserved) == .unknown)
    }

    /// The mirror of the synthesized zero: a zero the loop did publish, dropped.
    ///
    /// The newest sample is pulled back onto the last slot, so two cycles land
    /// there whenever the freshest one arrives after the reading the chart is
    /// anchored on. If the earlier reported thirty grams and the later reports
    /// nothing, skipping the zero leaves the earlier figure standing — a ribbon
    /// at the leading edge saying carbs are on board, beside a numeric tile
    /// reading the same loop and correctly saying they are not.
    @Test func apublishedZeroDisplacesTheFigureInItsSlot() throws {
        var samples: [CarbsOnBoardSample] = []
        for index in (slots - 6) ... (slots - 2) {
            samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 30))
        }
        samples.append(CarbsOnBoardSample(date: at(Double(slots - 1)).addingTimeInterval(-120), grams: 30))
        samples.append(CarbsOnBoardSample(date: at(Double(slots - 1)).addingTimeInterval(150), grams: 0))

        let ribbons = try #require(encoded(carbsOnBoard: samples))
        #expect(ribbons.carbs.allSatisfy { $0[0] + $0[1] < slots - 1 }, "no run may cover the slot the zero landed in")

        let back = ribbons.series(anchor: anchor, step: step)
        let now = RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(slots - 1)), observed: back.carbsObserved)
        #expect(now == .known(0), "the now slot came back \(now)")
        // And the figure before it is untouched.
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(slots - 2)), observed: back.carbsObserved) == .known(30))
    }

    /// A zero arriving while a run is still open ends the run there rather than
    /// removing it, so the figures before it survive.
    @Test func apublishedZeroEndsARunWithoutErasingIt() throws {
        var samples: [CarbsOnBoardSample] = []
        for index in 10 ... 14 {
            samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 30))
        }
        samples.append(CarbsOnBoardSample(date: at(14).addingTimeInterval(60), grams: 0))

        let ribbons = try #require(encoded(carbsOnBoard: samples))
        #expect(ribbons.carbs == [[10, 3, 30]])

        let back = ribbons.series(anchor: anchor, step: step)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(13), observed: back.carbsObserved) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(14), observed: back.carbsObserved) == .known(0))
    }

    /// The two sides of the rule, and each is the other's failing case.
    ///
    /// Absence inside an observed stretch is zero; absence outside every stretch
    /// is unknown. A test that only checked the first would pass on a payload
    /// that claimed the whole window, which is the confident zero this change
    /// exists to remove.
    @Test func absenceInsideTheObservedRangeIsZero() throws {
        let samples = [
            CarbsOnBoardSample(date: at(10), grams: 30),
            CarbsOnBoardSample(date: at(11), grams: 30),
            CarbsOnBoardSample(date: at(12), grams: 0),
        ]
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        #expect(ribbons.carbs == [[10, 1, 30]], "only the figure needs a run")
        #expect(ribbons.observed == [[10, 2]])

        let back = ribbons.series(anchor: anchor, step: step)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(11), observed: back.carbsObserved) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(12), observed: back.carbsObserved) == .known(0))
    }

    @Test func absenceOutsideTheObservedRangeIsUnknown() throws {
        let samples = [
            CarbsOnBoardSample(date: at(10), grams: 30),
            CarbsOnBoardSample(date: at(11), grams: 0),
        ]
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        let back = ribbons.series(anchor: anchor, step: step)

        // Before the stretch nobody had looked.
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(9), observed: back.carbsObserved) == .unknown)
        // And after it, immediately. A figure does not leave the stretch it was
        // reported in: the last observed sample is usually the now line, so
        // carrying it forward would assert nothing on board at this moment,
        // during the outage that stopped the reports.
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(12), observed: back.carbsObserved) == .unknown)
    }

    /// The outage case the range exists for. When devicestatus stops arriving
    /// there is nothing to state, and the stretch that follows is a second
    /// stretch rather than a continuation — so the gap between them cannot be
    /// read as the loop reporting nothing on board.
    @Test func anOutageFallsOutsideTheObservedRange() throws {
        var samples: [CarbsOnBoardSample] = []
        for index in 0 ..< 6 { samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 0)) }
        for index in 0 ..< 6 { samples.append(CarbsOnBoardSample(date: at(Double(20 + index)), grams: 0)) }
        let ribbons = try #require(encoded(carbsOnBoard: samples))

        #expect(ribbons.observed == [[0, 5], [20, 5]])
        let back = ribbons.series(anchor: anchor, step: step)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(6), observed: back.carbsObserved) == .unknown)
    }

    /// And a run that nothing follows ends as unknown rather than as zero, at
    /// the edge of observation rather than twenty minutes after it. The grid is
    /// what makes that possible: without it the hold has to guess, and a guess
    /// at the now line during a comms outage is the whole problem.
    @Test func aRunThatNothingFollowsGoesUnknownAtTheEdgeOfObservation() throws {
        let samples = [
            CarbsOnBoardSample(date: at(10), grams: 30),
            CarbsOnBoardSample(date: at(11), grams: 30),
        ]
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        let back = ribbons.series(anchor: anchor, step: step)

        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(11), observed: back.carbsObserved) == .known(30))
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(12), observed: back.carbsObserved) == .unknown)
    }

    /// Two loop cycles can land in one five-minute slot with different figures.
    /// Both became runs at the same slot, and the first one's terminator then
    /// wrote a zero into the next slot — mid-absorption, nowhere near the chart
    /// edge, so a fix aimed only at the now line would have left it standing.
    @Test func twoCyclesInOneSlotAreOneRunAtTheLaterFigure() throws {
        let samples = [
            CarbsOnBoardSample(date: at(10), grams: 40),
            CarbsOnBoardSample(date: at(10).addingTimeInterval(140), grams: 36),
            CarbsOnBoardSample(date: at(11), grams: 34),
        ]
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        #expect(ribbons.carbs == [[10, 0, 36], [11, 0, 34]])

        let back = ribbons.series(anchor: anchor, step: step)
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(11), observed: back.carbsObserved) == .known(34))
    }

    /// A cycle that lands after the reading the chart is anchored on used to
    /// round past the end and be dropped, because carbs were the only series
    /// without the pull-back the point events get.
    @Test func theFreshestCarbSampleIsNotRoundedOffTheEnd() throws {
        let samples = [CarbsOnBoardSample(date: at(Double(slots - 1) + 0.6), grams: 24)]
        let ribbons = try #require(encoded(carbsOnBoard: samples))

        #expect(ribbons.carbs == [[slots - 1, 0, 24]])
    }

    /// The whole point of the shape: it has to survive the wire, not just the
    /// two functions either side of it.
    @Test func theWholePayloadSurvivesJSON() throws {
        var boluses: [TreatmentEvent] = []
        for index in 0 ..< 8 {
            let amount: Double = 0.05 + Double(index) * 0.07
            boluses.append(TreatmentEvent(date: at(Double(index) * 3), amount: amount))
        }
        var onBoard: [CarbsOnBoardSample] = []
        for index in 0 ..< 20 {
            let grams: Double = 45 - Double(index) * 2
            onBoard.append(CarbsOnBoardSample(date: at(Double(index)), grams: grams))
        }
        let ribbons = try #require(encoded(
            insulin: boluses,
            carbsOnBoard: onBoard,
            rescue: [TreatmentEvent(date: at(30), amount: 16)]
        ))

        let data = try JSONEncoder().encode(ribbons)
        let decoded = try JSONDecoder().decode(LARibbons.self, from: data)
        #expect(decoded == ribbons)

        let before = ribbons.series(anchor: anchor, step: step)
        let after = decoded.series(anchor: anchor, step: step)
        #expect(before == after)
        #expect((before.insulin ?? []).count == 8)
        #expect((before.rescue ?? []).count == 1)
    }

    /// A run is one tuple on the wire, and one sample per slot once it is
    /// decoded. The sampler stops holding a figure after twenty minutes, so a
    /// run left as a single sample draws twenty minutes of ribbon and then
    /// unknown — a two-hour absorption reduced to its first four slots on the
    /// lock screen, with no sign that the rest is missing rather than zero.
    @Test func aLongRunHoldsItsFigureAllTheWayThrough() throws {
        let spans = Int((RibbonSampler.carbsOnBoardMaxHold / step).rounded()) * 6
        var samples: [CarbsOnBoardSample] = []
        for index in 0 ... spans {
            samples.append(CarbsOnBoardSample(date: at(Double(index)), grams: 40))
        }
        let ribbons = try #require(encoded(carbsOnBoard: samples))
        #expect(ribbons.carbs.count == 1, "a held figure is one run, not one tuple a slot")

        let back = ribbons.series(anchor: anchor, step: step)
        for index in 0 ... spans {
            let drawn = RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(index)), observed: back.carbsObserved)
            #expect(drawn == .known(40), "slot \(index) of \(spans) came back \(drawn)")
        }
        // What follows the run is nobody's report, not a reported zero.
        #expect(RibbonSampler.carbsOnBoard(back.carbsOnBoard, at: at(Double(spans + 1)), observed: back.carbsObserved) == .unknown)
    }

    /// The relay states where the ribbons it sent begin, because it drops
    /// ribbon history before it drops readings. Undecoded, the stretch it gave
    /// up arrives looking like a stretch in which no bolus was given — and on an
    /// event series that is a claim, not a silence.
    @Test func aTrimmedPayloadSaysWhereItsCoverageStarts() throws {
        let wire = Data(#"{"i":[[40,125]],"c":[[40,6,8]],"r":[],"f":36}"#.utf8)
        let ribbons = try JSONDecoder().decode(LARibbons.self, from: wire)
        let back = ribbons.series(anchor: anchor, step: step)

        #expect(back.coveredFrom == at(36))
        #expect((back.insulin ?? []).count == 1)
    }

    @Test func anUntrimmedPayloadBoundsNothing() throws {
        let wire = Data(#"{"i":[[40,125]],"c":[],"r":[]}"#.utf8)
        let ribbons = try JSONDecoder().decode(LARibbons.self, from: wire)

        #expect(ribbons.series(anchor: anchor, step: step).coveredFrom == nil)
    }

    /// The app's own producer covers whatever it was given, so it says nothing
    /// about coverage — and an absent key costs no bytes on a budget that has
    /// none to spare.
    @Test func whatTheAppBuildsItselfCarriesNoCoverageBound() throws {
        let ribbons = try #require(encoded(insulin: [TreatmentEvent(date: at(10), amount: 0.5)]))
        let wire = try #require(String(data: try JSONEncoder().encode(ribbons), encoding: .utf8))

        #expect(!wire.contains("\"f\""))
        #expect(ribbons.series(anchor: anchor, step: step).coveredFrom == nil)
    }

    @Test func noTreatmentsAtAllIsNoPayload() {
        #expect(encoded() == nil)
    }
}
