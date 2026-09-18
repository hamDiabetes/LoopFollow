// LoopFollow
// NightscoutDate.swift

import Foundation

/// When a Nightscout treatment happened.
///
/// In `Shared/` rather than beside the fetcher that reads it: the fetcher
/// compiles only into the widget extension, and no test target hosts that.
enum NightscoutDate {
    /// `mills` and `date` are epoch milliseconds where an uploader writes them;
    /// `created_at` is the ISO string every record has, and the one every bolus
    /// on this site arrives with. Uploaders differ on whether they print
    /// fractional seconds, and a formatter that insists either way silently
    /// fails on half the sites.
    static func eventDate(_ treatment: [String: Any]) -> Date? {
        for key in ["mills", "date"] {
            if let millis = (treatment[key] as? NSNumber)?.doubleValue, millis > 0 {
                return Date(timeIntervalSince1970: millis / 1000)
            }
        }
        guard let text = treatment["created_at"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
