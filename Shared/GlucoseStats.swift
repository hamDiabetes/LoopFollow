// LoopFollow
// GlucoseStats.swift

import Foundation

/// The stats panel's figures, computed where they are drawn.
///
/// Deliberately not sent from the relay. Every one of these depends on settings
/// the relay cannot see: the thresholds come from `UnitSettingsStore
/// .effectiveThresholds()`, which is 70-180 for TIR, 70-140 for TITR or a custom
/// pair; A1C is GMI or eHbA1c and reports in percent or mmol/mol; variability is
/// standard deviation or coefficient of variation. A relay-computed number would
/// keep answering the question that was in force at the last registration.
/// Computing here reads what the app publishes into the App Group, so the card
/// and the stats panel cannot drift apart.
///
/// The arithmetic mirrors `StatsData` in `LoopFollow/Controllers/Stats.swift`
/// line for line, including where that is surprising — see `averageMgdl`.
enum GlucoseStats {
    /// The window the app scores over. `MainViewController.updateStats` trims
    /// `bgData` to the last day before handing it to `StatsData`.
    static let window: TimeInterval = 24 * 3600

    /// Fewest readings worth quoting a figure from.
    ///
    /// Three hours at the usual five minute cadence. Below that a single
    /// excursion decides the whole percentage, and a slot labelled TIR reads as
    /// a statement about the day however few readings went into it. The stats
    /// panel shows a number regardless, but it shows it beside the reading count
    /// and the pie that give it context; a slot has neither, so it says nothing
    /// rather than something it cannot support.
    static let minimumReadings = 36

    struct Values {
        let percentLow: Double
        let percentInRange: Double
        let percentHigh: Double
        /// mg/dL, as `StatsData` holds it before display conversion.
        let averageMgdl: Double
        /// Population standard deviation in mg/dL.
        let standardDeviationMgdl: Double
        let coefficientOfVariation: Double
        let count: Int
    }

    /// How much of the window the readings must actually cover.
    ///
    /// A count is not enough. The series behind the Live Activity is only as
    /// long as the chart span someone picked — three hours by default — and
    /// three hours at the usual cadence clears `minimumReadings` exactly. So a
    /// slot labelled TIR would have answered a three-hour question in the same
    /// words the app's own panel uses for a day, and the two would disagree
    /// while claiming to be the same figure.
    ///
    /// Measured from the data rather than from the setting that produced it,
    /// because the series arrives from two places — the relay sends a full day,
    /// the app builds whatever the chart is drawn over — and only the data knows
    /// which one this is.
    static let minimumCoverage = 0.9

    /// - Returns: nil when the readings are too few, or do not span enough of
    ///   the window to be a statement about it.
    static func values(
        points: [GlucoseChartPoint],
        thresholds: (low: Double, high: Double),
        now: Date = Date()
    ) -> Values? {
        let cutoff = now.addingTimeInterval(-window)
        let recent = points.filter { $0.date >= cutoff }
        guard recent.count >= minimumReadings else { return nil }
        guard let oldest = recent.first?.date, let newest = recent.last?.date,
              newest.timeIntervalSince(oldest) >= window * minimumCoverage
        else { return nil }

        var countLow = 0
        var countHigh = 0
        var countRange = 0
        var total = 0

        for point in recent {
            // `StatsData` compares the raw mg/dL integer, so a reading exactly
            // on a threshold counts as in range at both ends.
            let sgv = Int(point.value)
            if Double(sgv) < thresholds.low {
                countLow += 1
            } else if Double(sgv) > thresholds.high {
                countHigh += 1
            } else {
                countRange += 1
            }
            total += sgv
        }

        // Integer division, matching `StatsData`, which divides two Ints and
        // converts afterwards. It truncates, so the average can read a whole
        // point below the true mean — reproduced rather than corrected, because
        // a card that disagreed with the stats panel by one would be the bug.
        let average = Double(total / recent.count)

        var partialSum = 0.0
        for point in recent {
            partialSum += (point.value - average) * (point.value - average)
        }
        let standardDeviation = (partialSum / Double(recent.count)).squareRoot()

        return Values(
            percentLow: Double(countLow) / Double(recent.count) * 100,
            percentInRange: Double(countRange) / Double(recent.count) * 100,
            percentHigh: Double(countHigh) / Double(recent.count) * 100,
            averageMgdl: average,
            standardDeviationMgdl: standardDeviation,
            coefficientOfVariation: average > 0 ? (standardDeviation / average) * 100 : 0,
            count: recent.count
        )
    }
}

// MARK: - Glycemic metric

/// A1C the way the app reports it, from `GlycemicMetricCalculator`.
///
/// Which formula and which output unit are both user settings, so the extension
/// reads them from the App Group rather than assuming the default pair.
enum GlucoseGlycemicMetric {
    static func value(averageMgdl: Double, mode: LAStatsMode) -> Double {
        let averageMmolL = averageMgdl * GlucoseConversion.mgDlToMmolL
        switch (mode.usesGMI, mode.reportsInMmolMol) {
        case (true, false): return 3.31 + (0.02392 * averageMgdl)
        case (true, true): return 12.71 + (4.70587 * averageMmolL)
        case (false, false): return (averageMgdl + 46.7) / 28.7
        case (false, true): return averageMmolL * 6.936514699616532 - 6.628248828291433
        }
    }
}

// MARK: - Display modes

/// Which conventions the stats panel is using, mirrored into the App Group so a
/// card outside the app can label and format these the way the app does.
struct LAStatsMode {
    /// GMI rather than estimated HbA1c.
    let usesGMI: Bool
    /// mmol/mol rather than percent.
    let reportsInMmolMol: Bool
    /// Standard deviation rather than coefficient of variation.
    let usesStdDev: Bool

    var glycemicLabel: String { usesGMI ? "GMI" : "A1C" }
    var variabilityLabel: String { usesStdDev ? "SD" : "CV" }
}
