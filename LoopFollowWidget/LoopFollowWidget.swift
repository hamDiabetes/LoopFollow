// LoopFollow
// LoopFollowWidget.swift

import AppIntents
import SwiftUI
import WidgetKit

/// Medium home screen widget: the configured span of glucose as a full bleed
/// backdrop, the current reading floating over it, and along the base three
/// configurable metrics with the refresh button in the fourth place.
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

    /// Height the metric row claims along the base, and the strip at the top the
    /// reading needs. The chart keeps its plot content out of both, so nothing it
    /// draws, the threshold lines above all, ends up underneath the text.
    private static let metricBandHeight: CGFloat = 50
    private static let readingHeadroom: CGFloat = 16

    /// Metric blocks along the base. The fourth place is the refresh button.
    private static let slotCount = 3

    /// Wide enough to take a thumb without the blocks beside it losing room.
    private static let refreshDiameter: CGFloat = 36

    /// Missing data is treated as stale: never show a number without an age. So
    /// is a reading from the future, whose real age is unknown rather than zero.
    private var isStale: Bool {
        guard let age = entry.snapshotAge, !entry.isTimestampAhead else { return true }
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

                    statusLine(snapshot)
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
    /// The relative style is unsigned, so it would count up from a timestamp in
    /// the future and read as fresh. That case is caught before it is drawn and
    /// says so plainly instead, since an age cannot be told from a wrong clock.
    ///
    /// Anchored to the reading, not to the entry that happens to be on screen.
    private func age(of snapshot: GlucoseSnapshot) -> some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .widgetAccentedRenderingMode(.desaturated)
                    .font(.system(size: 10.5))
            }
            Group {
                if entry.isTimestampAhead {
                    Text("clock ahead")
                } else {
                    Text(snapshot.updatedAt, style: .relative) + Text(" ago")
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .foregroundStyle(isStale ? AnyShapeStyle(Color(.systemOrange)) : AnyShapeStyle(.secondary))
    }

    /// The one line under the age. A loop that has stopped leads it, and the
    /// answer to a tap sits beside that rather than waiting for the line to come
    /// free: a stopped loop is exactly when the button gets pressed hardest, and
    /// a press that teaches nothing is the reason to press again.
    ///
    /// The refresh half never borrows the warning triangle. That glyph means the
    /// reading or the loop is in trouble, and a refresh that failed to reach the
    /// site says so in its own word instead.
    @ViewBuilder
    private func statusLine(_ snapshot: GlucoseSnapshot) -> some View {
        HStack(spacing: 7) {
            if snapshot.isNotLooping {
                warning("Not Looping", color: Color(.systemRed))
            }

            if entry.refreshDidFail {
                let orange = AnyShapeStyle(Color(.systemOrange))
                refreshNote("exclamationmark", "Refresh failed", settled: orange, arriving: orange)
            } else if let confirmation = entry.refreshConfirmation {
                refreshNote("checkmark", word(for: confirmation), settled: AnyShapeStyle(.secondary), arriving: AnyShapeStyle(.primary))
            }
        }
    }

    /// The answer to a tap, drawn under the age because that is the line it is
    /// most likely to be misread as correcting. It is about the check, never
    /// about the reading: the age above it is left exactly as it was, still
    /// counting, and where that age is a stale one this says outright that
    /// nothing newer exists so the warning above keeps the room.
    ///
    /// Short, and no clock of its own. It lies over the chart for the half minute
    /// it is up, which a fixed word can afford and a running count cannot. It
    /// arrives at full strength and settles to grey once the button is done
    /// acknowledging the tap, so the change is caught without the line going on
    /// competing with the reading.
    private func refreshNote(_ symbol: String, _ text: String, settled: AnyShapeStyle, arriving: AnyShapeStyle) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .widgetAccentedRenderingMode(.desaturated)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.system(size: 11, weight: entry.isFlashing ? .bold : .medium, design: .rounded))
        .foregroundStyle(entry.isFlashing ? arriving : settled)
    }

    private func word(for state: WidgetRefreshConfirmation) -> String {
        switch state {
        case .updated: return "Updated"
        case .upToDate: return isStale ? "No newer reading" : "Up to date"
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

    // Aligned by bottom edge: the button is a fixed circle and the blocks are
    // text of whatever height their labels need, so this is what puts them on
    // one line along the base.
    private var metricBand: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(entry.slots.prefix(Self.slotCount).enumerated()), id: \.offset) { _, option in
                WidgetSlotView(option: option, snapshot: entry.snapshot, isStale: isStale)
            }
            refreshButton
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Bottom right, where a thumb reaches it. It answers a tap by changing its
    /// glyph for a few seconds and then going back to the arrow, so the press
    /// visibly lands without the control ending up permanently dressed as
    /// something that has already been used. The circle and its border never
    /// change, which is what keeps it reading as pressable throughout.
    ///
    /// It is never the only answer. Everything it shows is said in words under
    /// the age as well, and those words outlast it.
    ///
    /// There is no state for the fetch itself. A marker written before the
    /// network call plus a `reloadTimelines` does not produce one: measured with
    /// the intent held open twelve seconds, the provider was not asked for a
    /// timeline once in that window, then asked 138ms after `perform` returned.
    /// The result is the first thing that can be drawn, so the job here is to
    /// make it impossible to miss when it lands.
    ///
    /// What it refreshes is the reading, the chart, and whatever the loop posts
    /// to devicestatus. The blocks it cannot source are rebuilt empty, so a
    /// metric never survives a refresh with an age it no longer has.
    @ViewBuilder
    private var refreshButton: some View {
        if entry.canRefresh {
            Button(intent: RefreshWidgetIntent()) {
                Image(systemName: Self.symbol(for: entry.refreshPhase))
                    .widgetAccentedRenderingMode(.desaturated)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(tint(for: entry.refreshPhase))
                    .frame(width: Self.refreshDiameter, height: Self.refreshDiameter)
                    .background(
                        // The plot runs underneath, so the glyph needs its own
                        // ground. The widget's background colour is what the mask
                        // already lets through elsewhere, which keeps the tinted
                        // and clear appearances free to substitute their own.
                        Circle().fill(isFullColor ? AnyShapeStyle(Color(.systemBackground).opacity(0.55)) : AnyShapeStyle(.tertiary))
                    )
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(refreshLabel)
        }
    }

    /// No glyph here implies motion: nothing animates between two timeline
    /// entries, so a part turned arrow would claim a spin that never happens.
    private static func symbol(for phase: WidgetRefreshButtonPhase) -> String {
        switch phase {
        case .idle, .failed: return "arrow.clockwise"
        case .justUpdated, .justChecked: return "checkmark"
        case .justFailed: return "exclamationmark"
        }
    }

    private func tint(for phase: WidgetRefreshButtonPhase) -> AnyShapeStyle {
        switch phase {
        case .idle, .justChecked: return AnyShapeStyle(.secondary)
        case .justUpdated: return AnyShapeStyle(Color(.systemGreen))
        case .justFailed, .failed: return AnyShapeStyle(Color(.systemOrange))
        }
    }

    private var refreshLabel: String {
        if entry.refreshDidFail { return "Refresh failed, try again" }
        switch entry.refreshConfirmation {
        case .updated: return "Refreshed"
        case .upToDate: return isStale ? "Refreshed, no newer reading" : "Refreshed, up to date"
        case .none: return "Refresh"
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if let series = entry.series {
            WidgetChartView(
                series: series,
                unit: unit,
                duration: entry.duration,
                style: entry.chartStyle,
                prediction: entry.prediction,
                horizon: entry.predictionHorizon,
                now: entry.date,
                bottomReserve: Self.metricBandHeight,
                topReserve: Self.readingHeadroom
            )
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
        // Lets the relay ask for a reload from outside the phone. Applied
        // unconditionally: pushHandler returns a different configuration type,
        // and WidgetBundleBuilder has no buildEither, so there is no way to
        // attach it behind an availability check. That is why this extension
        // targets iOS 26 while the app still targets 18.
        .pushHandler(LoopFollowWidgetPushHandler.self)
    }
}
