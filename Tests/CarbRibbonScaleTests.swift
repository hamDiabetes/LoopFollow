// LoopFollow
// CarbRibbonScaleTests.swift

import Foundation
@testable import LoopFollow
import Testing

/// That the carb ribbon is drawn at the scale somebody set.
///
/// The settings and their defaults are covered elsewhere. What is covered here
/// is the wiring: that the figures reach the shapes, and that rescue carbs are
/// still measured in the same gram.
struct CarbRibbonScaleTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func readings(_ count: Int) -> [GlucoseChartPoint] {
        (0 ..< count).map {
            GlucoseChartPoint(value: 120, date: anchor.addingTimeInterval(Double($0) * 300))
        }
    }

    private func ribbons(carbs grams: Double, points: [GlucoseChartPoint]) -> TreatmentRibbons {
        TreatmentRibbons(
            insulin: [],
            carbsOnBoard: points.map { CarbsOnBoardSample(date: $0.date, grams: grams) },
            rescue: [],
            carbsObserved: ObservedGrid(
                stretches: [ObservedStretch(from: points[0].date, through: points[points.count - 1].date.addingTimeInterval(660))],
                sampleSpacing: 660
            )
        )
    }

    private func thickness(
        grams: Double,
        fullScale: Double,
        heightShare: Double,
        kind: String = "carbs"
    ) -> Double? {
        let points = readings(5)
        let view = WidgetChartView(
            series: GlucoseChartSeries(points: points, updatedAt: points[points.count - 1].date),
            unit: .mgdl,
            duration: .threeHours,
            ribbons: ribbons(carbs: grams, points: points),
            now: points[points.count - 1].date,
            carbFullScaleGrams: fullScale,
            carbHeightShare: heightShare
        )
        let shapes = view.ribbonShapes(points, span: 100).shapes.filter { $0.kind == kind }
        guard let sample = shapes.flatMap({ $0.samples })
            .max(by: { abs($0.near - $0.far) < abs($1.near - $1.far) })
        else { return nil }
        return abs(sample.near - sample.far) / 100
    }

    /// The defaults were chosen to restate the fixed scale the ribbon shipped
    /// with. This asks the drawing rather than the arithmetic: a pair that
    /// multiplies out correctly but never reaches the shapes passes the other
    /// test and fails this one.
    @Test func theDefaultsDrawWhatTheFixedScaleDrew() throws {
        let drawn = try #require(thickness(
            grams: 30,
            fullScale: LAAppGroupSettings.defaultCarbFullScaleGrams,
            heightShare: LAAppGroupSettings.defaultCarbHeightShare
        ))

        #expect(abs(drawn - 30 * WidgetChartView.Ribbon.heightPerGram) < 0.0005)
    }

    @Test func aWiderFullScaleDrawsTheSameCarbsThinner() throws {
        let narrow = try #require(thickness(grams: 30, fullScale: 50, heightShare: 0.12))
        let wide = try #require(thickness(grams: 30, fullScale: 100, heightShare: 0.12))

        #expect(wide < narrow)
        #expect(abs(wide - narrow / 2) < 0.0005)
    }

    /// Justin chose the 50 g default knowing this: the ribbon stops growing at
    /// full scale rather than at the global cap, so a meal past it draws
    /// thinner than the fixed scale used to draw it.
    @Test func carbsPastFullScaleStopGrowing() throws {
        let atScale = try #require(thickness(grams: 50, fullScale: 50, heightShare: 0.12))
        let past = try #require(thickness(grams: 90, fullScale: 50, heightShare: 0.12))

        #expect(abs(past - atScale) < 0.0005)
    }

    /// The one invariant the rescue ribbon has: a rescue gram and a meal gram
    /// are the same unit, so the two ribbons can be read against each other.
    /// Rescue is drawn louder by a fixed multiplier, not by a scale of its own,
    /// which is what makes it follow the carb setting.
    ///
    /// Asked as a ratio between two scales rather than against an expected
    /// thickness: rescue carbs absorb, so the grams left at any given reading
    /// are a function of the rate and the clock, and an absolute figure here
    /// would be restating the absorption model rather than testing the wiring.
    @Test func theRescueRibbonFollowsTheCarbScale() throws {
        let points = readings(5)

        func rescueThickness(fullScale: Double) -> Double? {
            let view = WidgetChartView(
                series: GlucoseChartSeries(points: points, updatedAt: points[points.count - 1].date),
                unit: .mgdl,
                duration: .threeHours,
                ribbons: TreatmentRibbons(
                    insulin: [],
                    carbsOnBoard: [],
                    rescue: [TreatmentEvent(date: anchor.addingTimeInterval(-60), amount: 20)],
                    coveredFrom: anchor.addingTimeInterval(-3600),
                    carbsPerHour: 30
                ),
                now: points[points.count - 1].date,
                carbFullScaleGrams: fullScale,
                carbHeightShare: 0.12
            )
            return view.ribbonShapes(points, span: 100).shapes
                .filter { $0.kind == "rescue" }
                .flatMap(\.samples)
                .max(by: { abs($0.near - $0.far) < abs($1.near - $1.far) })
                .map { abs($0.near - $0.far) / 100 }
        }

        let narrow = try #require(rescueThickness(fullScale: 50))
        let wide = try #require(rescueThickness(fullScale: 100))

        #expect(narrow > 0)
        #expect(abs(wide - narrow / 2) < 0.0005)
    }
}
