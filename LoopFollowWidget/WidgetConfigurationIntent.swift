// LoopFollow
// WidgetConfigurationIntent.swift

import AppIntents

extension LiveActivitySlotOption: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Metric" }

    // The AppIntents metadata processor only accepts a literal dictionary here,
    // so these titles repeat `displayName` instead of deriving from it.
    static var caseDisplayRepresentations: [LiveActivitySlotOption: DisplayRepresentation] {
        [
            .none: "Empty",
            .delta: "Delta",
            .projectedBG: "Projected BG",
            .minMax: "Min/Max",
            .iob: "IOB",
            .cob: "COB",
            .recBolus: "Rec. Bolus",
            .autosens: "Autosens",
            .tdd: "TDD",
            .basal: "Basal",
            .pump: "Pump",
            .pumpBattery: "Pump Battery",
            .battery: "Battery",
            .target: "Target",
            .isf: "ISF",
            .carbRatio: "CR",
            .sage: "SAGE",
            .cage: "CAGE",
            .iage: "IAGE",
            .carbsToday: "Carbs today",
            .override: "Override",
            .profile: "Profile",
        ]
    }
}

extension WidgetChartDuration: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Duration" }

    // Literal for the same reason as the slot titles above.
    static var caseDisplayRepresentations: [WidgetChartDuration: DisplayRepresentation] {
        [
            .oneHour: "1h",
            .threeHours: "3h",
            .sixHours: "6h",
            .twelveHours: "12h",
            .twentyFourHours: "24h",
        ]
    }
}

/// Configuration presented by Edit Widget: the span of the chart, then one
/// parameter per metric block, using the same options as the Live Activity grid.
struct GlucoseWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Widget Options" }
    static var description: IntentDescription { "Choose the chart duration and the metrics shown beside it." }

    // Spelled out rather than read from WidgetChartDuration.standard, for the
    // compile-time constant rule noted below; keep the two in step.
    @Parameter(title: "Duration", default: .threeHours)
    var duration: WidgetChartDuration

    // @Parameter defaults must be compile-time constants, so these are spelled
    // out rather than read from LiveActivitySlotDefaults; keep the two in step.
    @Parameter(title: "Slot 1", default: .iob)
    var slot1: LiveActivitySlotOption

    @Parameter(title: "Slot 2", default: .cob)
    var slot2: LiveActivitySlotOption

    @Parameter(title: "Slot 3", default: .projectedBG)
    var slot3: LiveActivitySlotOption

    @Parameter(title: "Slot 4", default: LiveActivitySlotOption.none)
    var slot4: LiveActivitySlotOption

    var slots: [LiveActivitySlotOption] {
        [slot1, slot2, slot3, slot4]
    }
}
