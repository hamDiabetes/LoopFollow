// LoopFollow
// LoopFollowWidgetPushHandler.swift

import Foundation
import WidgetKit

/// Receives the push token WidgetKit issues for this widget and hands it to the
/// relay, which uses it to ask for a reload when Nightscout has something new.
///
/// The reload carries no data. The timeline provider already fetches on its own,
/// so the push only has to say that it is worth doing — which is the part iOS
/// will not do while the app is asleep.
struct LoopFollowWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets _: [WidgetInfo]) {
        let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
        RelayRegistration.submitWidgetToken(token)
    }
}
