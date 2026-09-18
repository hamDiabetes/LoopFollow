// LoopFollow
// MainChartRibbonModelTests.swift

import Foundation
import HealthKit
@testable import LoopFollow
import Testing

/// The data half of the main chart's ribbons: what the app already holds,
/// turned into the series the chart draws.
struct MainChartRibbonModelTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date {
        anchor.addingTimeInterval(minutes * 60)
    }

    private func note(_ minutes: Double, _ text: String, app: String?) -> DataStructs.noteStruct {
        DataStructs.noteStruct(date: at(minutes).timeIntervalSince1970, sgv: 100, note: text, app: app)
    }

    private func bolus(_ minutes: Double, _ units: Double) -> MainViewController.bolusGraphStruct {
        MainViewController.bolusGraphStruct(value: units, date: at(minutes).timeIntervalSince1970, sgv: 100)
    }

    // MARK: - Rescue carbs

    /// The trap this exists for. Trio writes its pump-suspend records as notes
    /// too, so an event-type or text test admits them and the chart grows
    /// rescue ribbons where nobody ate anything.
    @Test func onlyTheRescueUploadersNotesBecomeRescueCarbs() {
        let events = BGChartModel.rescueEvents(from: [
            note(0, "Rescue carbs: 12 g", app: "rescue-carbs"),
            note(10, "Pump suspended", app: "Trio"),
            note(20, "Rescue carbs: 8 g", app: "Trio"),
            note(30, "Rescue carbs: 20 g", app: nil),
        ])

        #expect(events.count == 1)
        #expect(events.first?.amount == 12)
        #expect(events.first?.date == at(0))
    }

    /// A note from the rescue uploader whose text does not carry grams has no
    /// amount to draw, and is dropped rather than guessed at.
    @Test func aRescueNoteWithoutGramsIsDropped() {
        let events = BGChartModel.rescueEvents(from: [
            note(0, "Rescue carbs", app: "rescue-carbs"),
            note(10, "Rescue carbs: 7.5 g", app: "rescue-carbs"),
        ])

        #expect(events.map(\.amount) == [7.5])
    }

    /// The field only tells the two apart if the read path keeps it. Nightscout
    /// hands `app` over on every treatment record and the note struct used to
    /// drop it on the floor.
    @MainActor
    @Test func theAppFieldSurvivesTheReadPath() {
        let controller = MainViewController()
        controller.processNotes(entries: [
            ["created_at": "2023-11-14T22:13:20.000Z", "notes": "Rescue carbs: 12 g", "app": "rescue-carbs"] as [String: AnyObject],
            ["created_at": "2023-11-14T22:23:20.000Z", "notes": "Pump suspended", "app": "Trio"] as [String: AnyObject],
        ])

        #expect(controller.noteGraphData.map(\.app) == ["Trio", "rescue-carbs"])
        #expect(BGChartModel.rescueEvents(from: controller.noteGraphData).map(\.amount) == [12])
    }

    /// The flag the dose series' nil turns on, which `updateTreatments` sets.
    /// It starts false, because a window nobody has asked about yet must not
    /// read as one that held nothing.
    ///
    /// The call site itself is not exercised here: `updateTreatments` traps on
    /// a view controller that has never loaded a view, and the trap takes the
    /// whole test process with it.
    @MainActor
    @Test func theTreatmentsFlagStartsFalseAndIsSetByHand() {
        let controller = MainViewController()
        #expect(controller.treatmentsLanded == false)

        controller.markTreatmentsLanded()
        #expect(controller.treatmentsLanded)
    }

    /// A failed store read must not take a drawn ribbon off the chart. The
    /// reads race the widget's atomic replaces, so a nil is "ask again", and
    /// letting it land would blank the ribbon until the read floor expires.
    @Test func aFailedReadKeepsWhatIsAlreadyHeld() {
        let held = carbHistory([0, 11])
        let fresh = carbHistory([0, 11, 22])

        #expect(MainViewController.holding(nil, over: held) == held)
        #expect(MainViewController.holding(fresh, over: held) == fresh)
        #expect(MainViewController.holding(nil, over: nil) as CarbsOnBoardHistory? == nil)
    }

    // MARK: - Doses

    @Test func bolusesAndMicrobolusesAreOneSeriesInDateOrder() {
        let events = BGChartModel.insulinEvents(
            boluses: [bolus(30, 2.0), bolus(0, 1.0)],
            smbs: [bolus(15, 0.15), bolus(20, 0)]
        )

        #expect(events.map(\.date) == [at(0), at(15), at(30)])
        #expect(events.map(\.amount) == [1.0, 0.15, 2.0])
    }

    // MARK: - Assembly

    private func carbHistory(_ minutes: [Double]) -> CarbsOnBoardHistory {
        let samples = minutes.map { CarbsOnBoardSample(date: at($0), grams: 10) }
        return CarbsOnBoardHistory(samples: samples, updatedAt: samples.last?.date ?? anchor)
    }

    private func insulinHistory(_ minutes: [Double]) -> InsulinOnBoardHistory {
        let samples = minutes.map { InsulinOnBoardSample(date: at($0), units: 1) }
        return InsulinOnBoardHistory(samples: samples, updatedAt: samples.last?.date ?? anchor)
    }

    private func ribbons(
        treatmentsLanded: Bool = true,
        notes: [DataStructs.noteStruct] = [],
        carbs: CarbsOnBoardHistory? = nil,
        insulin: InsulinOnBoardHistory? = nil,
        carbsPerHour: Double? = nil
    ) -> TreatmentRibbons? {
        BGChartModel.makeRibbons(
            boluses: [bolus(0, 1.0)],
            smbs: [],
            notes: notes,
            treatmentsLanded: treatmentsLanded,
            windowStart: at(-24 * 60),
            carbsOnBoard: carbs,
            insulinOnBoard: insulin,
            carbsPerHour: carbsPerHour
        )
    }

    /// A phone whose app has been closed has no store and no download. Painting
    /// a ribbon across that stretch would be inventing data on a chart somebody
    /// doses from, so nothing is published at all.
    @Test func nothingObservedPublishesNoRibbons() {
        #expect(ribbons(treatmentsLanded: false) == nil)
    }

    /// The reason the stores hand over a grid: inside it an absent sample is a
    /// reported zero, outside it nobody was watching, and the two cannot be
    /// drawn the same way.
    ///
    /// Each grid is checked by its extent rather than by existing, because the
    /// two series were watched for different lengths here -- eleven minutes
    /// apart -- and handing the chart the wrong one would otherwise pass. A
    /// grid that is merely present says nothing about which series it describes.
    @Test func theStoresObservationIsCarriedThrough() throws {
        let assembled = ribbons(carbs: carbHistory([0, 11, 22]), insulin: insulinHistory([0, 11]))

        #expect(assembled?.carbsOnBoard?.count == 3)
        #expect(assembled?.insulinOnBoard?.count == 2)

        let carbsObserved = try #require(assembled?.carbsObserved)
        let insulinObserved = try #require(assembled?.insulinObserved)

        // Each stretch runs one second short of the slot after its last sample.
        let hold = CarbsOnBoardHistory.publicationInterval - 1
        #expect(carbsObserved.stretches.last?.through == at(22).addingTimeInterval(hold))
        #expect(insulinObserved.stretches.last?.through == at(11).addingTimeInterval(hold))

        // Twenty-five minutes in, carbs were still being watched and insulin
        // was not, so nothing there can be read as a reported zero.
        #expect(carbsObserved.stretch(containing: at(25)) != nil)
        #expect(insulinObserved.stretch(containing: at(25)) == nil)
    }

    /// An empty array is the answer "nothing was given"; nil is "nobody asked".
    /// A download that has not landed must not read as a quiet day.
    @Test func doseSeriesAreUnknownUntilTheDownloadLands() {
        let landed = ribbons(carbs: carbHistory([0]))
        #expect(landed?.insulin?.isEmpty == false)
        #expect(landed?.rescue?.isEmpty == true)
        #expect(landed?.coveredFrom == at(-24 * 60))

        let pending = ribbons(treatmentsLanded: false, carbs: carbHistory([0]))
        #expect(pending?.insulin == nil)
        #expect(pending?.rescue == nil)
        #expect(pending?.coveredFrom == nil)
    }

    /// Without the profile's figure the rescue ribbon falls back to a different
    /// rate than the widget uses, and the same entry draws two lengths.
    @Test func theProfilesAbsorptionRateReachesTheRibbons() {
        #expect(ribbons(carbs: carbHistory([0]), carbsPerHour: 21)?.carbsPerHour == 21)
        #expect(ribbons(carbs: carbHistory([0]))?.carbsPerHour == nil)
    }
}

/// The profile half, which runs against the shared ProfileManager and so runs
/// one test at a time.
@Suite(.serialized)
struct MainChartProfileTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func profile(carbsHr: String, units: String = "mg/dl", targetLow: Double = 100, targetHigh: Double = 100) throws -> NSProfile {
        let json = """
        {
          "defaultProfile": "Default",
          "units": "\(units)",
          "store": {
            "Default": {
              "basal": [{"value": 0.5, "time": "00:00", "timeAsSeconds": 0}],
              "sens": [{"value": 50, "time": "00:00", "timeAsSeconds": 0}],
              "carbratio": [{"value": 25, "time": "00:00", "timeAsSeconds": 0}],
              "target_low": [{"value": \(targetLow), "time": "00:00", "timeAsSeconds": 0},
                             {"value": 110, "time": "12:00", "timeAsSeconds": 43200}],
              "target_high": [{"value": \(targetHigh), "time": "00:00", "timeAsSeconds": 0},
                              {"value": 110, "time": "12:00", "timeAsSeconds": 43200}],
              "timezone": "America/Boise",
              "units": "\(units)",
              "carbs_hr": \(carbsHr)
            }
          }
        }
        """
        return try JSONDecoder().decode(NSProfile.self, from: Data(json.utf8))
    }

    /// The family's site writes it as a number; other uploaders write the same
    /// figure as a string.
    @Test func carbsPerHourIsReadWhicheverWayItIsWritten() throws {
        ProfileManager.shared.loadProfile(from: try profile(carbsHr: "21"))
        #expect(ProfileManager.shared.carbsPerHour == 21)

        ProfileManager.shared.loadProfile(from: try profile(carbsHr: "\"21\""))
        #expect(ProfileManager.shared.carbsPerHour == 21)
    }

    /// A figure that is neither costs the rescue ribbon its rate. It must not
    /// cost the profile its basal rates, sensitivities and targets with it.
    @Test func anUnreadableCarbsPerHourDoesNotTakeTheProfileWithIt() throws {
        let loaded = try profile(carbsHr: "\"none\"")
        ProfileManager.shared.loadProfile(from: loaded)

        #expect(ProfileManager.shared.carbsPerHour == nil)
        #expect(ProfileManager.shared.basalSchedule.count == 1)
        #expect(ProfileManager.shared.targetLowSchedule.count == 2)
    }

    /// Built from the schedules already loaded, and in mg/dL wherever the
    /// profile's own units land.
    @Test func theTargetLineComesOutOfTheLoadedSchedule() throws {
        ProfileManager.shared.loadProfile(from: try profile(carbsHr: "21"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Boise")!
        let midnight = calendar.startOfDay(for: anchor)

        let series = ProfileManager.shared.targetSeries(from: midnight, to: midnight.addingTimeInterval(20 * 3600))
        #expect(series?.target(at: midnight.addingTimeInterval(3600)) == 100)
        #expect(series?.target(at: midnight.addingTimeInterval(13 * 3600)) == 110)
    }

    /// A profile in mmol/L states its targets in mmol/L, and the chart is drawn
    /// in mg/dL. A cast rather than a conversion would draw the target line at
    /// five and a half.
    @Test func mmolProfileTargetsAreConvertedNotCast() throws {
        ProfileManager.shared.loadProfile(from: try profile(carbsHr: "21", units: "mmol", targetLow: 5.5, targetHigh: 5.5))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Boise")!
        let midnight = calendar.startOfDay(for: anchor)

        let series = ProfileManager.shared.targetSeries(from: midnight, to: midnight.addingTimeInterval(3600))
        let target = try #require(series?.target(at: midnight.addingTimeInterval(600)))
        #expect(abs(target - 99.09) < 0.5)
    }

    /// Where a profile aims at a band the chart has no line to draw, and a line
    /// down the middle of a range is a target nobody set.
    @Test func aProfileAimingAtARangeProducesNoLine() throws {
        ProfileManager.shared.loadProfile(from: try profile(carbsHr: "21", targetLow: 90, targetHigh: 120))

        #expect(ProfileManager.shared.targetSeries(from: anchor, to: anchor.addingTimeInterval(3600)) == nil)
    }
}
