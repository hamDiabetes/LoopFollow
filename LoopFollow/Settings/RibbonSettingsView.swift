// LoopFollow
// RibbonSettingsView.swift

import SwiftUI

/// The treatment ribbons drawn over the glucose trace. One screen because one
/// set of numbers: the main chart, the widget and the Live Activity all draw
/// from the same App Group values.
struct RibbonSettingsView: View {
    /// Each list brackets its own default rather than starting at it, since
    /// what makes a scale legible is a person's usual peak.
    static let insulinFullScaleOptions: [Double] = [2, 3, 4, 6, 8, 10]
    static let carbFullScaleOptions: [Double] = [20, 30, 50, 75, 100, 150]

    /// A quarter of the plot was the old fixed cap and is the top of this range.
    static let heightOptions: [Double] = [0.08, 0.1, 0.12, 0.15, 0.2, 0.25]

    @State private var showInsulin: Bool = LAAppGroupSettings.showInsulinRibbon()
    @State private var insulinFullScale: Double = LAAppGroupSettings.insulinFullScaleUnits()
    @State private var insulinHeight: Double = LAAppGroupSettings.insulinHeightShare()

    @State private var showCarbs: Bool = LAAppGroupSettings.showCarbRibbon()
    @State private var carbFullScale: Double = LAAppGroupSettings.carbFullScaleGrams()
    @State private var carbHeight: Double = LAAppGroupSettings.carbHeightShare()

    @State private var showRescue: Bool = LAAppGroupSettings.showRescueRibbon()

    var body: some View {
        Form {
            Section(
                header: Text("Insulin"),
                footer: Text("How much insulin on board draws the blue ribbon at its full height, and how tall that is. Above the cap the ribbon stops growing rather than taking over the chart.")
            ) {
                Toggle("Show Insulin Ribbon", isOn: $showInsulin)

                if showInsulin {
                    Picker("Full at", selection: $insulinFullScale) {
                        ForEach(Self.insulinFullScaleOptions, id: \.self) { units in
                            Text(String(format: "%.0f U", units)).tag(units)
                        }
                    }
                    Picker("Height", selection: $insulinHeight) {
                        ForEach(Self.heightOptions, id: \.self) { share in
                            Text(String(format: "%.0f%%", share * 100)).tag(share)
                        }
                    }
                }
            }

            Section(
                header: Text("Carbs"),
                footer: Text("The same two numbers for the purple ribbon, in grams on board.")
            ) {
                Toggle("Show Carb Ribbon", isOn: $showCarbs)

                if showCarbs {
                    Picker("Full at", selection: $carbFullScale) {
                        ForEach(Self.carbFullScaleOptions, id: \.self) { grams in
                            Text(String(format: "%.0f g", grams)).tag(grams)
                        }
                    }
                    Picker("Height", selection: $carbHeight) {
                        ForEach(Self.heightOptions, id: \.self) { share in
                            Text(String(format: "%.0f%%", share * 100)).tag(share)
                        }
                    }
                }
            }

            Section(
                header: Text("Rescue Carbs"),
                footer: Text("Rescue carbs are drawn on the carb scale, at twice the weight, so a gram reads the same in both ribbons. They follow the carb settings above.")
            ) {
                Toggle("Show Rescue Carb Ribbon", isOn: $showRescue)
            }
        }
        .onChange(of: showInsulin) { newValue in
            LAAppGroupSettings.setShowInsulinRibbon(newValue)
            applied("insulin ribbon visibility changed")
        }
        .onChange(of: insulinFullScale) { newValue in
            LAAppGroupSettings.setInsulinFullScaleUnits(newValue)
            applied("insulin scale changed")
        }
        .onChange(of: insulinHeight) { newValue in
            LAAppGroupSettings.setInsulinHeightShare(newValue)
            applied("insulin height changed")
        }
        .onChange(of: showCarbs) { newValue in
            LAAppGroupSettings.setShowCarbRibbon(newValue)
            applied("carb ribbon visibility changed")
        }
        .onChange(of: carbFullScale) { newValue in
            LAAppGroupSettings.setCarbFullScaleGrams(newValue)
            applied("carb scale changed")
        }
        .onChange(of: carbHeight) { newValue in
            LAAppGroupSettings.setCarbHeightShare(newValue)
            applied("carb height changed")
        }
        .onChange(of: showRescue) { newValue in
            LAAppGroupSettings.setShowRescueRibbon(newValue)
            applied("rescue ribbon visibility changed")
        }
        .preferredColorScheme(Storage.shared.appearanceMode.value.colorScheme)
        .navigationBarTitle("Ribbons", displayMode: .inline)
    }

    /// The widget picks the new values up on its next timeline rather than on
    /// demand, so there is nothing to tell it.
    private func applied(_ reason: String) {
        Observable.shared.chartSettingsChanged.value = true
        #if !targetEnvironment(macCatalyst)
            LiveActivityManager.shared.refreshFromCurrentState(reason: reason)
        #endif
    }
}
