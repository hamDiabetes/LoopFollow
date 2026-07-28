// LoopFollow
// RemoteContentView.swift

import SwiftUI

struct RemoteContentView: View {
    @ObservedObject private var device = Storage.shared.device
    @ObservedObject private var remoteType = Storage.shared.remoteType

    var body: some View {
        Group {
            switch remoteType.value {
            case .trc:
                if device.value == "Trio" {
                    TrioRemoteControlView(viewModel: TrioRemoteControlViewModel())
                } else {
                    Text("Trio Remote Control is only supported for 'Trio'")
                }

            case .loopAPNS:
                LoopAPNSRemoteView()

            case .none:
                Text("Please select a Remote Type in Settings.")
            }
        }
        // Every route into remote control passes through here, however it was
        // configured, so this catches the settings toggle, an in-settings QR
        // import and a restore alike. Remote commands answer over a notification.
        .onAppear {
            if remoteType.value != .none {
                NotificationAuthorization.requestIfNeeded()
            }
        }
    }
}
