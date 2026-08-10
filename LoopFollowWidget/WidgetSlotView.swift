// LoopFollow
// WidgetSlotView.swift

import SwiftUI

/// One configurable metric block, mirroring the Live Activity grid cell but
/// sized for the home screen and using system colors instead of white on tint.
struct WidgetSlotView: View {
    let option: LiveActivitySlotOption
    let snapshot: GlucoseSnapshot?

    /// The readings behind the stats-panel figures. Nil leaves those slots
    /// showing an em dash rather than a number computed from nothing.
    let series: GlucoseChartSeries?

    /// These values come from the same snapshot as the glucose reading, so they
    /// are demoted alongside it rather than reading as current.
    let isStale: Bool

    private var value: String {
        guard let snapshot else { return "—" }
        return slotFormattedValue(option: option, snapshot: snapshot, series: series)
    }

    var body: some View {
        if option == .none {
            // Height is pinned: an unconstrained Color would claim the whole
            // widget and push the metric row off its edge.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text(option.gridLabel.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
