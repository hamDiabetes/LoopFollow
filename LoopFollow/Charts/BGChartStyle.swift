// LoopFollow
// BGChartStyle.swift

import Foundation

/// How the main chart draws the glucose trace.
///
/// `dots` is what the chart has always drawn and stays the default: a coloured
/// point per reading, over an optional line. `area` is the Live Activity's
/// look — one splined trace with a fill beneath it, coloured by the band it is
/// crossing, and no dots.
///
/// The two are not a skin over the same marks. The dot style colours each
/// reading on its own, while the area style colours a *run* and meets the next
/// one on the threshold crossing, so a trace on its way up changes colour where
/// it passes the line rather than at the first reading beyond it.
enum BGChartStyle: String, Codable, CaseIterable, Identifiable {
    case dots
    case area

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dots: return "Dots"
        case .area: return "Area"
        }
    }
}
