// LoopFollow
// LoopFollowWidget.swift

import SwiftUI
import WidgetKit

/// Medium home screen widget: the configured span of glucose as a full bleed
/// backdrop, the current reading floating over it and four configurable metrics
/// along the base.
struct LoopFollowWidgetView: View {
    let entry: GlucoseWidgetEntry

    /// The tinted and clear home screen appearances flatten every colour to one
    /// tint, so those layouts have to separate by opacity rather than by hue.
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// Past this age the reading is no longer presented as the current value.
    private static let staleThreshold: TimeInterval = 15 * 60

    private static let inset: CGFloat = 15

    /// The series outlives the snapshot, so fall back to what the app last
    /// published rather than to mg/dL, which would relabel an mmol/L chart.
    private var unit: GlucoseSnapshot.Unit {
        entry.snapshot?.unit ?? LAAppGroupSettings.preferredUnit()
    }

    private var thresholds: (low: Double, high: Double) {
        LAAppGroupSettings.thresholdsMgdl()
    }

    private var isFullColor: Bool {
        renderingMode == .fullColor
    }

    /// Missing data is treated as stale: never show a number without an age.
    private var isStale: Bool {
        guard let age = entry.snapshotAge else { return true }
        return age >= Self.staleThreshold
    }

    private func color(forMgdl mgdl: Double, thresholds t: (low: Double, high: Double)) -> Color {
        if mgdl < t.low {
            return Color(.systemRed)
        } else if mgdl > t.high {
            return Color(.systemOrange)
        } else {
            return Color(.systemGreen)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(legibilityMask)

            reading(thresholds: thresholds)
                .padding(.leading, Self.inset)
                .padding(.top, 10)

            metricBand
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Legibility

    /// The chart is the whole widget, so the reading and the metrics sit on top of
    /// it. Rather than laying a panel over the plot, the plot is held back
    /// underneath them: a dense run of points keeps its shape at a fraction of the
    /// contrast, and what shows through is the widget's own background, which the
    /// tinted and clear appearances are free to replace.
    ///
    /// Every ramp reaches its end value inside the widget, so no edge is drawn.
    private var legibilityMask: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                // Union of the two quiet regions. Overlapping soft fields compose
                // to a soft field, so the seam between them is not a contour.
                ZStack {
                    Rectangle()
                        .fill(.black)
                        .mask(Self.ramp(.leading, .trailing, hold: 0.36, fade: 0.66))
                        .mask(Self.ramp(.top, .bottom, hold: 0.5, fade: 0.88))

                    Rectangle()
                        .fill(.black)
                        .mask(Self.ramp(.bottom, .top, hold: 0.22, fade: 0.46))
                }
                .compositingGroup()
                .opacity(0.86)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    private static func ramp(_ from: UnitPoint, _ to: UnitPoint, hold: Double, fade: Double) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: hold),
                .init(color: .clear, location: fade),
            ],
            startPoint: from,
            endPoint: to
        )
    }

    /// A halo in the widget's background colour, so the reading survives where the
    /// corner fade has run out. Tinted appearances would flatten it into a glow.
    @ViewBuilder
    private func halo(_ content: some View) -> some View {
        if isFullColor, entry.series != nil {
            content
                .shadow(color: Color(.systemBackground).opacity(0.9), radius: 1.5)
                .shadow(color: Color(.systemBackground).opacity(0.45), radius: 5)
        } else {
            content
        }
    }

    @ViewBuilder
    private func reading(thresholds t: (low: Double, high: Double)) -> some View {
        if let snapshot = entry.snapshot {
            halo(
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(LAFormat.glucose(snapshot))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(color(forMgdl: snapshot.glucose, thresholds: t)))
                            .minimumScaleFactor(0.6)

                        if !isStale {
                            Text(LAFormat.trendArrow(snapshot))
                                .font(.system(size: 21, weight: .semibold, design: .rounded))
                                .foregroundStyle(color(forMgdl: snapshot.glucose, thresholds: t))
                        }
                    }
                    .widgetAccentable()

                    // The delta holds its place whatever the age: a stale reading
                    // still moved, and that direction is worth keeping on screen.
                    Text("\(LAFormat.delta(snapshot)) \(unit.displayName)")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    age(of: snapshot)

                    if snapshot.isNotLooping {
                        warning("Not Looping", color: Color(.systemRed))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            )
        } else {
            halo(
                VStack(alignment: .leading, spacing: 3) {
                    warning("No glucose", color: Color(.systemOrange), size: 16)
                    Text("Open Loop Follow")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            )
        }
    }

    /// How long ago the reading was taken, as a clock the system advances itself.
    /// A date styled `Text` is re-rendered on screen without spending a timeline
    /// reload, so the age stays true through exactly the stretches where WidgetKit
    /// is refusing to refresh us and an old number is most dangerous.
    ///
    /// The offset style rounds down to a single unit, so the age reads as calmly as
    /// the five minute data behind it and is never overstated as fresh. It is also
    /// the only style that signs its output: a reading timestamped in the future by
    /// a skewed clock shows as a minus instead of passing for current.
    ///
    /// Anchored to the reading, not to the entry that happens to be on screen.
    private func age(of snapshot: GlucoseSnapshot) -> some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .widgetAccentedRenderingMode(.desaturated)
                    .font(.system(size: 10.5))
            }
            (Text(snapshot.updatedAt, style: .offset) + Text(" ago"))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(isStale ? AnyShapeStyle(Color(.systemOrange)) : AnyShapeStyle(.secondary))
    }

    private func warning(_ text: String, color: Color, size: CGFloat = 11.5) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .widgetAccentedRenderingMode(.desaturated)
                .font(.system(size: size - 1.5))
            Text(text)
                .font(.system(size: size, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
    }

    // MARK: - Metrics

    // Aligned by top edge: an empty slot draws no text, so it has no baseline.
    private var metricBand: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(entry.slots.prefix(4).enumerated()), id: \.offset) { _, option in
                WidgetSlotView(option: option, snapshot: entry.snapshot, isStale: isStale)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if let series = entry.series {
            WidgetChartView(series: series, unit: unit, duration: entry.duration)
        } else if entry.snapshot != nil {
            // Only worth saying when a reading is on screen without a chart to put
            // it in. With nothing at all, the reading block already says so.
            // Centred in what the floating reading leaves free, not in the widget.
            Text("No recent glucose")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 110)
        }
    }
}

struct LoopFollowWidget: Widget {
    private let kind = "LoopFollowWidget"

    /// Keeps side-by-side builds apart in the widget gallery.
    private var galleryName: String {
        LAAppGroupSettings.showDisplayName() ? LAAppGroupSettings.displayName() : "Loop Follow"
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: GlucoseWidgetConfigurationIntent.self,
            provider: WidgetTimelineProvider()
        ) { entry in
            LoopFollowWidgetView(entry: entry)
        }
        .configurationDisplayName(galleryName)
        .description("Glucose at a glance.")
        .supportedFamilies([.systemMedium])
        // The chart runs to the edges, so the widget insets its own content.
        .contentMarginsDisabled()
    }
}
