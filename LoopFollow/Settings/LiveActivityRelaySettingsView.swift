// LoopFollow
// LiveActivityRelaySettingsView.swift

// LiveActivityRelayClient is unavailable on macCatalyst, so this screen is too.
#if !targetEnvironment(macCatalyst)

    import SwiftUI

    struct LiveActivityRelaySettingsView: View {
        @State private var enabled: Bool = Storage.shared.laRelayEnabled.value
        @State private var relayURL: String = Storage.shared.laRelayURL.value
        @State private var secret: String = Storage.shared.laRelaySecret.value

        private var urlValid: Bool {
            guard let url = URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return url.scheme == "https" || url.scheme == "http"
        }

        private var canEnable: Bool {
            urlValid && !secret.isEmpty
        }

        private var lastRegistered: String {
            let stamp = Storage.shared.laRelayLastRegisteredAt.value
            guard stamp > 0 else { return "Never" }
            return Self.stamp(Date(timeIntervalSince1970: stamp))
        }

        private var widgetTokenStatus: String {
            guard let date = LAAppGroupSettings.widgetTokenAttemptAt() else { return "Never" }
            let tail = LAAppGroupSettings.widgetTokenTail()
            return tail.isEmpty ? Self.stamp(date) : "…\(tail) · \(Self.stamp(date))"
        }

        private var widgetReloadStatus: String {
            guard let date = LAAppGroupSettings.widgetReloadAt() else { return "Never" }
            return Self.stamp(date)
        }

        private static func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }

        var body: some View {
            Form {
                Section(
                    footer: Text("The Live Activity is updated by a relay that watches Nightscout, so it stays current while LoopFollow is not running. While this is on, LoopFollow stops updating the Live Activity itself.")
                ) {
                    Toggle("Update from Relay", isOn: $enabled)
                        .disabled(!canEnable && !enabled)
                }

                Section(header: Text("Relay")) {
                    HStack {
                        Text("URL")
                        TextField("https://relay.example", text: $relayURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        if !relayURL.isEmpty {
                            Image(systemName: urlValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(urlValid ? .green : .orange)
                                .accessibilityLabel(urlValid ? "Valid URL" : "Invalid URL")
                        }
                    }
                    HStack {
                        Text("Secret")
                        TogglableSecureInput(
                            placeholder: "Shared secret",
                            text: $secret,
                            style: .singleLine
                        )
                    }
                }

                Section(
                    header: Text("Status"),
                    footer: Text("Tokens are sent to the relay when iOS issues them, which happens shortly after the Live Activity starts and whenever they rotate. If this says Never after enabling, restart the Live Activity.")
                ) {
                    HStack {
                        Text("Last registered")
                        Spacer()
                        Text(lastRegistered).foregroundColor(.secondary)
                    }
                    if !Storage.shared.laRelayLastError.value.isEmpty {
                        Text(Storage.shared.laRelayLastError.value)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Section(
                    header: Text("Widget"),
                    footer: Text("The relay can also ask the home screen widget to refresh. iOS budgets these and delivers them when it chooses, so the widget may redraw later than the relay asked. A token that never arrives means the widget is not receiving push updates at all.")
                ) {
                    HStack {
                        Text("Token sent")
                        Spacer()
                        Text(widgetTokenStatus).foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Widget last drew")
                        Spacer()
                        Text(widgetReloadStatus).foregroundColor(.secondary)
                    }
                    if !LAAppGroupSettings.widgetTokenError().isEmpty {
                        Text(LAAppGroupSettings.widgetTokenError())
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("Live Activity Relay")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: relayURL) { newValue in
                Storage.shared.laRelayURL.value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                LiveActivityRelayClient.shared.mirrorSettingsForExtensions()
            }
            .onChange(of: secret) { newValue in
                Storage.shared.laRelaySecret.value = newValue
                LiveActivityRelayClient.shared.mirrorSettingsForExtensions()
            }
            .onChange(of: enabled) { newValue in
                Storage.shared.laRelayEnabled.value = newValue
                LiveActivityRelayClient.shared.mirrorSettingsForExtensions()
                // Register straight away rather than waiting for the next rotation:
                // iOS may not reissue a token for hours, and until the relay holds
                // one it cannot push anything.
                if newValue {
                    LiveActivityRelayClient.shared.register(
                        updateToken: LiveActivityManager.shared.currentPushToken,
                        pushToStartToken: Storage.shared.laPushToStartToken.value.isEmpty
                            ? nil
                            : Storage.shared.laPushToStartToken.value
                    )
                }
            }
            .preferredColorScheme(Storage.shared.appearanceMode.value.colorScheme)
        }
    }

#endif
