// LoopFollow
// LoopFollowLiveActivity.swift

import ActivityKit
import SwiftUI
import WidgetKit

/// Builds the shared Dynamic Island content used by the Live Activity widget.
private func makeDynamicIsland(context: ActivityViewContext<GlucoseLiveActivityAttributes>) -> DynamicIsland {
    DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            Link(destination: URL(string: "\(AppGroupID.urlScheme)://la-tap")!) {
                DynamicIslandLeadingView(snapshot: context.state.snapshot)
                    .overlay(RenewalOverlayView(show: context.state.snapshot.showRenewalOverlay))
            }
            .id(context.state.seq)
        }
        DynamicIslandExpandedRegion(.trailing) {
            Link(destination: URL(string: "\(AppGroupID.urlScheme)://la-tap")!) {
                DynamicIslandTrailingView(snapshot: context.state.snapshot, series: context.state.chart?.series)
                    .overlay(RenewalOverlayView(show: context.state.snapshot.showRenewalOverlay))
            }
            .id(context.state.seq)
        }
        DynamicIslandExpandedRegion(.bottom) {
            Link(destination: URL(string: "\(AppGroupID.urlScheme)://la-tap")!) {
                DynamicIslandBottomView(snapshot: context.state.snapshot)
                    .overlay(RenewalOverlayView(show: context.state.snapshot.showRenewalOverlay, showText: true))
            }
            .id(context.state.seq)
        }
    } compactLeading: {
        DynamicIslandCompactLeadingView(snapshot: context.state.snapshot)
            .id(context.state.seq)
    } compactTrailing: {
        DynamicIslandCompactTrailingView(snapshot: context.state.snapshot)
            .id(context.state.seq)
    } minimal: {
        DynamicIslandMinimalView(snapshot: context.state.snapshot)
            .id(context.state.seq)
    }
    .keylineTint(LAColors.keyline(for: context.state.snapshot).opacity(0.75))
}

// MARK: - Live Activity widget

/// Single widget for the Live Activity. Enables the supplemental `.small` family
/// (CarPlay Dashboard / Watch Smart Stack) and routes the lock screen layout via
/// `LockScreenFamilyAdaptiveView`.
struct LoopFollowLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GlucoseLiveActivityAttributes.self) { context in
            LockScreenFamilyAdaptiveView(state: context.state)
                .id(context.state.seq)
                .background(
                    LALivenessMarker(
                        seq: context.state.seq,
                        producedAt: context.state.producedAt
                    )
                )
                .activitySystemActionForegroundColor(.white)
                .contentMargins(.all, 0)
                .widgetURL(URL(string: "\(AppGroupID.urlScheme)://la-tap")!)
        } dynamicIsland: { context in
            makeDynamicIsland(context: context)
        }
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Family-adaptive wrapper (Lock Screen / CarPlay / Watch Smart Stack)

/// Reads the activityFamily environment value and routes to the appropriate layout.
/// - `.small` → CarPlay Dashboard & Watch Smart Stack
/// - everything else → full lock screen layout
private struct LockScreenFamilyAdaptiveView: View {
    let state: GlucoseLiveActivityAttributes.ContentState

    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        if activityFamily == .small {
            SmallFamilyView(snapshot: state.snapshot, series: state.chart?.series)
                .activityBackgroundTint(Color.black.opacity(0.25))
        } else {
            LockScreenLiveActivityView(state: state)
                .activityBackgroundTint(LAColors.backgroundTint(for: state.snapshot))
        }
    }
}

// MARK: - Small family view (CarPlay Dashboard + Watch Smart Stack)

private struct SmallFamilyView: View {
    let snapshot: GlucoseSnapshot
    let series: GlucoseChartSeries?

    /// Unit label for the right slot — ISF appends "/U", other glucose slots
    /// use the plain glucose unit, non-glucose slots return nil.
    private func rightSlotUnitLabel(for slot: LiveActivitySlotOption) -> String? {
        guard slot.isGlucoseUnit else { return nil }
        if slot == .isf { return snapshot.unit.displayName + "/U" }
        return snapshot.unit.displayName
    }

    var body: some View {
        let rightSlot = LAAppGroupSettings.smallWidgetSlot()

        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(LAFormat.glucose(snapshot))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LAColors.keyline(for: snapshot))

                    Text(LAFormat.trendArrow(snapshot))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(LAColors.keyline(for: snapshot))
                }

                Text("\(LAFormat.delta(snapshot)) \(snapshot.unit.displayName)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            .layoutPriority(1)

            Spacer()

            if rightSlot != .none {
                if let unitLabel = rightSlotUnitLabel(for: rightSlot) {
                    // Use ViewThatFits so the unit label appears on surfaces with
                    // enough vertical space (CarPlay) and is omitted where it doesn't
                    // fit (Watch Smart Stack).
                    ViewThatFits(in: .vertical) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(rightSlot.gridLabel)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                            Text(slotFormattedValue(option: rightSlot, snapshot: snapshot, series: series))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(unitLabel)
                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(rightSlot.gridLabel)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.65))
                            Text(slotFormattedValue(option: rightSlot, snapshot: snapshot, series: series))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(rightSlot.gridLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(slotFormattedValue(option: rightSlot, snapshot: snapshot, series: series))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(10)
    }
}

// MARK: - Lock Screen Contract View

/// The lock screen card, laid out like the home screen widget: the readings as
/// a full bleed backdrop, the current value floating over them, and the metrics
/// along the base.
///
/// The chart arrives in the push rather than from the App Group. That cache is
/// written by the app, and the app being asleep is the whole reason the relay
/// exists — a Live Activity reading it would draw a history that stopped when
/// the phone did, under a reading that did not.
private struct LockScreenLiveActivityView: View {
    let state: GlucoseLiveActivityAttributes.ContentState

    /// Past this age the reading is no longer presented as the current value.
    private static let staleThreshold: TimeInterval = 15 * 60

    private static let inset: CGFloat = 14

    /// The lock screen sizes a Live Activity to the height its content asks for,
    /// up to the system limit. `maxHeight: .infinity` only permits height, it
    /// does not request any, so without this the card collapsed to the reading
    /// and the metric band and squeezed the chart into what was left. A medium
    /// widget is about 158pt, which is what this layout was drawn against.
    private static let cardHeight: CGFloat = 160

    /// What the chart keeps its plot out of, so the threshold lines never end up
    /// under the text.
    private static let metricBandHeight: CGFloat = 46
    private static let readingHeadroom: CGFloat = 14

    private var snapshot: GlucoseSnapshot { state.snapshot }

    private var readingAt: Date { snapshot.updatedAt }

    /// A reading from the future has an unknown age rather than a zero one, so
    /// it is called stale and says why instead of counting up from nothing.
    private var isTimestampAhead: Bool {
        readingAt.timeIntervalSinceNow > 60
    }

    private var isStale: Bool {
        isTimestampAhead || -readingAt.timeIntervalSinceNow >= Self.staleThreshold
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(legibilityScrim)

            reading
                .padding(.leading, Self.inset)
                .padding(.top, 9)

            if LAAppGroupSettings.showDisplayName() {
                Text(LAAppGroupSettings.displayName())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .padding(.trailing, Self.inset)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .shadow(color: .black.opacity(0.5), radius: 3)
            }

            metricBand
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .overlay(
            Group {
                if snapshot.isNotLooping {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: UIColor.systemRed).opacity(0.85))

                        Text("Not Looping")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .tracking(1.5)
                    }
                }
            }
        )
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.gray.opacity(0.9))

                Text("Tap to update")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .opacity(snapshot.showRenewalOverlay ? 1 : 0)
        )
    }

    // MARK: - Legibility

    /// The widget holds its plot back under the text by subtracting from a mask,
    /// because the tinted home screen appearances need the system's own
    /// background to show through where it does. A Live Activity is always full
    /// colour over a tint this view already chose, so darkening the plot is the
    /// same picture arrived at by plain compositing — no blend modes and no
    /// offscreen group, which is worth having on a surface rendered out of
    /// process from an archive.
    private var legibilityScrim: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.36),
                    .init(color: .clear, location: 0.72),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.5),
                        .init(color: .clear, location: 0.9),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0),
                    .init(color: .clear, location: 0.5),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Reading

    private var reading: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(LAFormat.glucose(snapshot))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isStale ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.white))
                    .minimumScaleFactor(0.6)
                    .layoutPriority(3)

                if !isStale {
                    Text(LAFormat.trendArrow(snapshot))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Text("\(LAFormat.delta(snapshot)) \(snapshot.unit.displayName)")
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.80))

            age

            ActiveAdjustmentsView(snapshot: snapshot)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    /// A clock the system advances on its own, so the age stays true through the
    /// stretches where nothing is arriving and an old number is most dangerous.
    /// Anchored to the reading rather than to the push that carried it.
    private var age: some View {
        HStack(spacing: 3) {
            if isStale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
            }
            Group {
                if isTimestampAhead {
                    Text("clock ahead")
                } else {
                    Text(readingAt, style: .relative) + Text(" ago")
                }
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .foregroundStyle(isStale ? AnyShapeStyle(Color(uiColor: .systemOrange)) : AnyShapeStyle(.white.opacity(0.70)))
    }

    // MARK: - Metrics

    private var metricBand: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(LAAppGroupSettings.slots().enumerated()), id: \.offset) { _, option in
                BandSlotView(option: option, snapshot: snapshot, series: state.chart?.series)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    // MARK: - Chart

    @ViewBuilder
    private var chart: some View {
        if let chart = state.chart, let series = chart.series {
            WidgetChartView(
                series: series,
                unit: snapshot.unit,
                duration: LAAppGroupSettings.chartDuration(),
                style: LAAppGroupSettings.chartStyle(),
                prediction: chart.prediction,
                horizon: LAAppGroupSettings.predictionHorizon(),
                // The newest reading rather than the moment of the draw. A Live
                // Activity can sit on screen for hours past its last push, and a
                // window measured from now would walk the readings off the edge
                // while the age beside them went on counting.
                now: chart.newestReadingAt ?? readingAt,
                bottomReserve: Self.metricBandHeight,
                topReserve: Self.readingHeadroom
            )
        } else {
            Color.clear
        }
    }
}

/// A metric along the base of the card. Unlike the widget's fixed blocks these
/// share the width evenly, because the card is as wide as the phone and four of
/// them have to fit on the narrow ones too.
private struct BandSlotView: View {
    let option: LiveActivitySlotOption
    let snapshot: GlucoseSnapshot
    let series: GlucoseChartSeries?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if option != .none {
                Text(option.gridLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(slotFormattedValue(option: option, snapshot: snapshot, series: series))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-size gray overlay shown 30 minutes before the LA renewal deadline.
/// Applied to both the lock screen view and each expanded Dynamic Island region.
private struct RenewalOverlayView: View {
    let show: Bool
    var showText: Bool = false

    var body: some View {
        ZStack {
            Color.gray.opacity(0.9)
            if showText {
                Text("Tap to update")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .opacity(show ? 1 : 0)
    }
}

/// Conditional row showing the active override and/or temp target with a
/// self-ticking countdown. Shared by the lock screen card and the expanded
/// Dynamic Island bottom region; renders nothing when neither is active.
private struct ActiveAdjustmentsView: View {
    let snapshot: GlucoseSnapshot

    /// Above this remaining time the ticker is skipped (name/value only) —
    /// a multi-hour or multi-day countdown reads poorly in the compact row.
    private static let tickerMaxRemaining: TimeInterval = 2 * 3600

    // Ends already in the past are stale data waiting for the next refresh —
    // drop them rather than render a dead 0:00 timer.
    private var overrideEnd: Date? {
        guard let t = snapshot.overrideEndAt, t > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    private var tempTargetEnd: Date? {
        guard let t = snapshot.tempTargetEndAt, t > Date().timeIntervalSince1970 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// nil end with a non-nil name means indefinite — keep showing the name;
    /// a timed override whose end has passed is hidden entirely.
    private var overrideName: String? {
        guard let name = snapshot.override else { return nil }
        if snapshot.overrideEndAt != nil, overrideEnd == nil { return nil }
        return name
    }

    private var tempTargetText: String? {
        guard tempTargetEnd != nil else { return nil }
        return LAFormat.tempTargetValue(snapshot)
    }

    var body: some View {
        if overrideName != nil || tempTargetText != nil {
            HStack(spacing: 5) {
                Text("⏱")
                    .font(.system(size: 11))
                if let name = overrideName {
                    Text(name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .layoutPriority(1)
                    if let end = overrideEnd, end.timeIntervalSinceNow <= Self.tickerMaxRemaining {
                        countdown(to: end)
                    }
                }
                if overrideName != nil, tempTargetText != nil {
                    Text("·")
                        .foregroundStyle(.white.opacity(0.5))
                }
                if let tt = tempTargetText, let end = tempTargetEnd {
                    Text("TT \(tt)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if end.timeIntervalSinceNow <= Self.tickerMaxRemaining {
                        countdown(to: end)
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func countdown(to end: Date) -> some View {
        // Text(timerInterval:) claims flexible width; cap it so the row stays centered.
        Text(timerInterval: Date() ... end, countsDown: true)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: end.timeIntervalSinceNow >= 3600 ? 62 : 46, alignment: .leading)
    }
}

// MARK: - Dynamic Island

private struct DynamicIslandLeadingView: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if snapshot.isNotLooping {
            Text("⚠️ Not Looping")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .tracking(1.0)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(LAFormat.glucose(snapshot))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LAColors.keyline(for: snapshot))
                    Text(LAFormat.trendArrow(snapshot))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(LAColors.keyline(for: snapshot))
                }
                Text("\(LAFormat.delta(snapshot)) \(snapshot.unit.displayName)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

private struct DynamicIslandTrailingView: View {
    let snapshot: GlucoseSnapshot
    let series: GlucoseChartSeries?

    var body: some View {
        if snapshot.isNotLooping {
            EmptyView()
        } else {
            let slot = LAAppGroupSettings.smallWidgetSlot()
            if slot != .none {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(slot.gridLabel)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(slotFormattedValue(option: slot, snapshot: snapshot, series: series))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.trailing, 6)
            }
        }
    }
}

private struct DynamicIslandBottomView: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if snapshot.isNotLooping {
            Text("Loop has not reported in 15+ minutes")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            VStack(spacing: 2) {
                ActiveAdjustmentsView(snapshot: snapshot)
                Text("Updated at: \(LAFormat.updated(snapshot))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

private struct DynamicIslandCompactTrailingView: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if snapshot.isNotLooping {
            Text("Not Looping")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Text(LAFormat.delta(snapshot))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

private struct DynamicIslandCompactLeadingView: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if snapshot.isNotLooping {
            Text("⚠️")
                .font(.system(size: 14))
        } else {
            // The arrow rides with the reading rather than the delta: which way
            // it is going matters at a glance, and the compact leading slot is
            // narrow enough that the number gives up a couple of points for it.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(LAFormat.glucose(snapshot))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)

                Text(LAFormat.trendArrow(snapshot))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

private struct DynamicIslandMinimalView: View {
    let snapshot: GlucoseSnapshot

    var body: some View {
        if snapshot.isNotLooping {
            Text("⚠️")
                .font(.system(size: 12))
        } else {
            Text(LAFormat.glucose(snapshot))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Threshold-driven colors

private enum LAColors {
    static func backgroundTint(for snapshot: GlucoseSnapshot) -> Color {
        let mgdl = snapshot.glucose
        let t = LAAppGroupSettings.thresholdsMgdl()
        let low = t.low
        let high = t.high

        if mgdl < low {
            let raw = 0.48 + (0.85 - 0.48) * ((low - mgdl) / (low - 54.0))
            let opacity = min(max(raw, 0.48), 0.85)
            return Color(uiColor: UIColor.systemRed).opacity(opacity)
        } else if mgdl > high {
            let raw = 0.44 + (0.85 - 0.44) * ((mgdl - high) / (324.0 - high))
            let opacity = min(max(raw, 0.44), 0.85)
            return Color(uiColor: UIColor.systemOrange).opacity(opacity)
        } else {
            return Color(uiColor: UIColor.systemGreen).opacity(0.36)
        }
    }

    static func keyline(for snapshot: GlucoseSnapshot) -> Color {
        let mgdl = snapshot.glucose
        let t = LAAppGroupSettings.thresholdsMgdl()
        let low = t.low
        let high = t.high

        if mgdl < low {
            return Color(uiColor: UIColor.systemRed)
        } else if mgdl > high {
            return Color(uiColor: UIColor.systemOrange)
        } else {
            return Color(uiColor: UIColor.systemGreen)
        }
    }
}
