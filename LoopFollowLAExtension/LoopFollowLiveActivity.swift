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
                DynamicIslandTrailingView(snapshot: context.state.snapshot)
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
            SmallFamilyView(snapshot: state.snapshot)
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
                            Text(slotFormattedValue(option: rightSlot, snapshot: snapshot))
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
                            Text(slotFormattedValue(option: rightSlot, snapshot: snapshot))
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
                        Text(slotFormattedValue(option: rightSlot, snapshot: snapshot))
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

private struct LockScreenLiveActivityView: View {
    let state: GlucoseLiveActivityAttributes.ContentState

    var body: some View {
        let s = state.snapshot
        let slotConfig = LAAppGroupSettings.slots()

        VStack(spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(LAFormat.glucose(s))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .allowsTightening(true)
                            .layoutPriority(3)

                        Text(LAFormat.trendArrow(s))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text("Delta: \(LAFormat.delta(s))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.80))
                        .lineLimit(1)
                }
                .frame(minWidth: 160, maxWidth: 184, alignment: .leading)
                .layoutPriority(2)

                Rectangle()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 1)
                    .padding(.vertical, 8)

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        SlotView(option: slotConfig[0], snapshot: s)
                        SlotView(option: slotConfig[1], snapshot: s)
                    }
                    HStack(spacing: 12) {
                        SlotView(option: slotConfig[2], snapshot: s)
                        SlotView(option: slotConfig[3], snapshot: s)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ActiveAdjustmentsView(snapshot: s)

            Text(LAAppGroupSettings.showDisplayName()
                ? "\(LAAppGroupSettings.displayName()) — \(LAFormat.updated(s))"
                : "Last Update: \(LAFormat.updated(s))")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .overlay(
            Group {
                if state.snapshot.isNotLooping {
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
            .opacity(state.snapshot.showRenewalOverlay ? 1 : 0)
        )
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

private struct MetricBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.80)

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
                .layoutPriority(1)
        }
        .frame(width: 72, alignment: .leading)
    }
}

private struct SlotView: View {
    let option: LiveActivitySlotOption
    let snapshot: GlucoseSnapshot

    var body: some View {
        if option == .none {
            Color.clear
                .frame(width: 72, height: 36)
        } else {
            MetricBlock(label: option.gridLabel, value: slotFormattedValue(option: option, snapshot: snapshot))
        }
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
                    Text(slotFormattedValue(option: slot, snapshot: snapshot))
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
            Text(LAFormat.glucose(snapshot))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
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
