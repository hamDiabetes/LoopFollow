// LoopFollow
// GlucoseLiveActivityAttributes.swift

// swiftformat:disable indent
#if !targetEnvironment(macCatalyst)

import ActivityKit
import Foundation

struct GlucoseLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let snapshot: GlucoseSnapshot
        let seq: Int
        let reason: String
        let producedAt: Date

        /// The history the lock screen draws behind the reading. Optional
        /// because the app builds this state too, from a cache it can read
        /// directly, and because a relay that has not yet seen enough readings
        /// sends none rather than a chart of one point.
        let chart: LAChart?

        init(snapshot: GlucoseSnapshot, seq: Int, reason: String, producedAt: Date, chart: LAChart? = nil) {
            self.snapshot = snapshot
            self.seq = seq
            self.reason = reason
            self.producedAt = producedAt
            self.chart = chart
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            snapshot = try container.decode(GlucoseSnapshot.self, forKey: .snapshot)
            seq = try container.decode(Int.self, forKey: .seq)
            reason = try container.decode(String.self, forKey: .reason)
            let producedAtInterval = try container.decode(Double.self, forKey: .producedAt)
            producedAt = Date(timeIntervalSince1970: producedAtInterval)
            chart = try container.decodeIfPresent(LAChart.self, forKey: .chart)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(snapshot, forKey: .snapshot)
            try container.encode(seq, forKey: .seq)
            try container.encode(reason, forKey: .reason)
            try container.encode(producedAt.timeIntervalSince1970, forKey: .producedAt)
            try container.encodeIfPresent(chart, forKey: .chart)
        }

        private enum CodingKeys: String, CodingKey {
            case snapshot, seq, reason, producedAt, chart
        }
    }

    /// Reserved for future metadata. Keep minimal for stability.
    let title: String
}

#endif
