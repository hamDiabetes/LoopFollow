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

    /// Height of the chart backdrop. What is left below it is the metric band.
    private static let chartHeight: CGFloat = 112

    private static let inset: CGFloat = 15

    private static let ageFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute]
        f.maximumUnitCount = 1
        return f
    }()

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

    /// The last entry of a timeline can be left on screen indefinitely, so its
    /// age is only a lower bound and is marked with a "+".
    private var ageText: String {
        guard let age = entry.snapshotAge, let text = Self.ageFormatter.string(from: max(age, 60)) else { return "" }
        return entry.isLast ? text + "+" : text
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
                .frame(height: Self.chartHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask(quietCorner)

            reading(thresholds: thresholds)
                .padding(.leading, Self.inset)
                .padding(.top, 10)

            metricBand
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Reading

    /// Holds the chart back where the reading sits rather than covering it: a
    /// dense run of points keeps its shape there at a fraction of the contrast.
    /// Both ramps reach zero inside the widget, so the fade has no visible edge.
    private var quietCorner: some View {
        Rectangle()
            .fill(.black)
            .overlay {
                Rectangle()
                    .fill(.black.opacity(0.86))
                    .mask(Self.ramp(.leading, .trailing, hold: 0.33, fade: 0.62))
                    .mask(Self.ramp(.top, .bottom, hold: 0.74, fade: 1))
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

                    Text(LAFormat.updated(snapshot))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if isStale || snapshot.isNotLooping {
                        HStack(spacing: 7) {
                            if isStale {
                                warning("\(ageText) old", color: Color(.systemOrange))
                            }
                            if snapshot.isNotLooping {
                                warning("Not Looping", color: Color(.systemRed))
                            }
                        }
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
        } else {
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
