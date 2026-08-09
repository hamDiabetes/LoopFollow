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
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: Date(timeIntervalSince1970: stamp))
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
            }
            .navigationTitle("Live Activity Relay")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: relayURL) { newValue in
                Storage.shared.laRelayURL.value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .onChange(of: secret) { newValue in
                Storage.shared.laRelaySecret.value = newValue
            }
            .onChange(of: enabled) { newValue in
                Storage.shared.laRelayEnabled.value = newValue
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
