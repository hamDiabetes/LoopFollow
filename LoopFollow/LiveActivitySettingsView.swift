// LoopFollow
// LiveActivitySettingsView.swift

#if !targetEnvironment(macCatalyst)

    import SwiftUI

    struct LiveActivitySettingsView: View {
        @State private var laEnabled: Bool = Storage.shared.laEnabled.value
        @State private var restartConfirmed = false
        @State private var slots: [LiveActivitySlotOption] = LAAppGroupSettings.slots()
        @State private var smallWidgetSlot: LiveActivitySlotOption = LAAppGroupSettings.smallWidgetSlot()
        @State private var chartDuration: WidgetChartDuration = LAAppGroupSettings.chartDuration()
        @State private var chartStyle: WidgetChartStyle = LAAppGroupSettings.chartStyle()
        @State private var predictionHorizon: WidgetPredictionHorizon = LAAppGroupSettings.predictionHorizon()
        @State private var keyId: String = Storage.shared.lfKeyId.value
        @State private var apnsKey: String = Storage.shared.lfApnsKey.value
        @State private var relayEnabled: Bool = Storage.shared.laRelayEnabled.value

        /// The metrics sit in one row along the bottom of the card now, not in a
        /// 2x2 grid, so the labels name positions along that row.
        private let slotLabels = ["Left", "Center left", "Center right", "Right"]

        private var apnsConfigured: Bool {
            APNsCredentialValidator.isFullyConfigured(keyId: keyId, apnsKey: apnsKey)
        }

        var body: some View {
            Form {
                Section(
                    header: Text("Live Activity"),
                    footer: Text(relayEnabled
                        ? "The relay updates the Live Activity, so no APNs credentials are needed on this phone."
                        : "Live Activity updates require APNs credentials. Configure them in Settings → APN.")
                ) {
                    Toggle("Enable Live Activity", isOn: $laEnabled)
                }

                if laEnabled {
                    // The relay signs on this device's behalf, so an unset key is
                    // the intended state rather than a misconfiguration.
                    if !apnsConfigured, !relayEnabled {
                        Section {
                            Label {
                                Text("APNs credentials are missing or invalid — Live Activity updates will not work. Open Settings → APN to fix.")
                                    .font(.callout)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    Section {
                        Button(restartConfirmed ? "Live Activity Restarted" : "Restart Live Activity") {
                            LiveActivityManager.shared.forceRestart()
                            restartConfirmed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                restartConfirmed = false
                            }
                        }
                        .disabled(restartConfirmed)
                    }

                    Section(
                        footer: Text("Keep the Live Activity updating while LoopFollow is not running.")
                    ) {
                        NavigationLink("Live Activity Relay") {
                            LiveActivityRelaySettingsView()
                        }
                    }
                }

                Section(
                    header: Text("Chart"),
                    footer: Text(relayEnabled
                        ? "The readings drawn behind the Live Activity. The relay sends a full day and the card draws the span chosen here."
                        : "The readings drawn behind the Live Activity, from what the app has cached.")
                ) {
                    Picker("Span", selection: $chartDuration) {
                        ForEach(WidgetChartDuration.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Picker("Style", selection: $chartStyle) {
                        ForEach(WidgetChartStyle.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Picker("Forecast", selection: $predictionHorizon) {
                        ForEach(WidgetPredictionHorizon.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section(
                    header: Text("Metrics"),
                    footer: Text("The row along the bottom of the Live Activity, in order from left to right.")
                ) {
                    ForEach(0 ..< 4, id: \.self) { index in
                        Picker(slotLabels[index], selection: Binding(
                            get: { slots[index] },
                            set: { selectSlot($0, at: index) }
                        )) {
                            ForEach(LiveActivitySlotOption.gridCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    }
                }

                Section(
                    header: Text("CarPlay / Watch"),
                    footer: Text("The compact card has room for one metric beside the reading.")
                ) {
                    Picker("Metric", selection: Binding(
                        get: { smallWidgetSlot },
                        set: { newValue in
                            smallWidgetSlot = newValue
                            LAAppGroupSettings.setSmallWidgetSlot(newValue)
                            LiveActivityManager.shared.refreshFromCurrentState(reason: "small widget slot changed")
                        }
                    )) {
                        ForEach(LiveActivitySlotOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
            }
            .onReceive(Storage.shared.laEnabled.$value) { newValue in
                if newValue != laEnabled { laEnabled = newValue }
            }
            .onReceive(Storage.shared.lfKeyId.$value) { newValue in
                if newValue != keyId { keyId = newValue }
            }
            .onReceive(Storage.shared.lfApnsKey.$value) { newValue in
                if newValue != apnsKey { apnsKey = newValue }
            }
            .onReceive(Storage.shared.laRelayEnabled.$value) { newValue in
                if newValue != relayEnabled { relayEnabled = newValue }
            }
            .onChange(of: chartDuration) { newValue in
                LAAppGroupSettings.setChartDuration(newValue)
                LiveActivityManager.shared.refreshFromCurrentState(reason: "chart span changed")
            }
            .onChange(of: chartStyle) { newValue in
                LAAppGroupSettings.setChartStyle(newValue)
                LiveActivityManager.shared.refreshFromCurrentState(reason: "chart style changed")
            }
            .onChange(of: predictionHorizon) { newValue in
                LAAppGroupSettings.setPredictionHorizon(newValue)
                LiveActivityManager.shared.refreshFromCurrentState(reason: "forecast horizon changed")
            }
            .onChange(of: laEnabled) { newValue in
                Storage.shared.laEnabled.value = newValue
                if newValue {
                    LiveActivityManager.shared.forceRestart()
                } else {
                    LiveActivityManager.shared.end(dismissalPolicy: .immediate)
                }
            }
            .preferredColorScheme(Storage.shared.appearanceMode.value.colorScheme)
            .navigationTitle("Live Activity")
            .navigationBarTitleDisplayMode(.inline)
        }

        /// Selects an option for the given slot index, enforcing uniqueness:
        /// if the chosen option is already in another slot, that slot is cleared to `.none`.
        private func selectSlot(_ option: LiveActivitySlotOption, at index: Int) {
            if option != .none {
                for i in 0 ..< slots.count where i != index && slots[i] == option {
                    slots[i] = .none
                }
            }
            slots[index] = option
            LAAppGroupSettings.setSlots(slots)
            LiveActivityManager.shared.refreshFromCurrentState(reason: "slot config changed")
        }
    }
#endif
