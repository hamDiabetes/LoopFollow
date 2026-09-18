// LoopFollow
// DeviceStatusHistory.swift

import Foundation

/// The on-board series read out of a window of devicestatus records.
///
/// The app's poll asks Nightscout for every record since the newest one it
/// holds, so the records behind the newest are the hours the app was not
/// running. They carry the same `IOB` and `COB` fields the header is drawn
/// from; this reads those and nothing else, which is why it is a free function
/// over the raw records rather than a second pass through the display parsers.
///
/// **Nothing here invents a sample.** A record without a usable figure, or
/// without a cycle time to sit at, is dropped, and the gap it leaves is what
/// `ObservedGrid` reads as a stretch nobody heard.
enum DeviceStatusHistory {
    struct OnBoard: Equatable {
        var carbs: [CarbsOnBoardSample]
        var insulin: [InsulinOnBoardSample]

        var isEmpty: Bool { carbs.isEmpty && insulin.isEmpty }
    }

    /// Carbs on board as the openaps record states it.
    ///
    /// Shared with the display path rather than copied: some uploaders put the
    /// figure only in the human-readable `reason` line, and a second
    /// implementation of that fallback would drift into drawing a ribbon the
    /// header disagrees with.
    static func carbsOnBoard(fromOpenAPS enactedOrSuggested: [String: AnyObject]) -> Double? {
        if let cob = enactedOrSuggested["COB"] as? Double {
            return cob
        }

        guard let reason = enactedOrSuggested["reason"] as? String,
              let regex = try? NSRegularExpression(pattern: "COB: (\\d+(?:\\.\\d+)?)"),
              let match = regex.firstMatch(in: reason, range: NSRange(location: 0, length: reason.utf16.count))
        else { return nil }

        return Double((reason as NSString).substring(with: match.range(at: 1)))
    }

    /// Both series out of a window of records, oldest first.
    ///
    /// Ordering is imposed here rather than assumed. Nightscout answers newest
    /// first, the stores hold oldest first, and `ObservedGrid` reads spacing off
    /// consecutive samples — a series handed over in the wrong order reports one
    /// stretch per sample and draws as the scattered blocks this exists to fix.
    static func onBoard(from records: [[String: AnyObject]], formatter: ISO8601DateFormatter) -> OnBoard {
        var carbs: [CarbsOnBoardSample] = []
        var insulin: [InsulinOnBoardSample] = []

        for record in records {
            if let openAPS = record["openaps"] as? [String: AnyObject] {
                // A failed cycle publishes its failure and no figures. It is a
                // record the query returned and still a moment nothing was
                // reported for.
                guard openAPS["failureReason"] == nil,
                      let cycle = openAPS["suggested"] as? [String: AnyObject] ?? openAPS["enacted"] as? [String: AnyObject],
                      let date = openAPSCycleDate(cycle, formatter: formatter)
                else { continue }

                if let grams = carbsOnBoard(fromOpenAPS: cycle) {
                    carbs.append(CarbsOnBoardSample(date: date, grams: grams))
                }
                // `openaps.iob.iob` is what the header reads, and the two agree
                // on every one of 527 records across a day here. The cycle's own
                // `IOB` is the fallback rather than the source, so a site that
                // publishes only one of them still draws.
                if let units = (openAPS["iob"] as? [String: AnyObject])?["iob"] as? Double ?? cycle["IOB"] as? Double {
                    insulin.append(InsulinOnBoardSample(date: date, units: units))
                }
            } else if let loop = record["loop"] as? [String: AnyObject] {
                guard loop["failureReason"] == nil,
                      let date = loopCycleDate(record, loop: loop, formatter: formatter)
                else { continue }

                if let grams = (loop["cob"] as? [String: AnyObject])?["cob"] as? Double {
                    carbs.append(CarbsOnBoardSample(date: date, grams: grams))
                }
                if let units = (loop["iob"] as? [String: AnyObject])?["iob"] as? Double {
                    insulin.append(InsulinOnBoardSample(date: date, units: units))
                }
            }
        }

        return OnBoard(
            carbs: carbs.sorted { $0.date < $1.date },
            insulin: insulin.sorted { $0.date < $1.date }
        )
    }

    /// The cycle's own moment, on the same two fields and in the same order the
    /// header uses. A record can be uploaded well after the cycle it describes,
    /// and the ribbon has to sit where the insulin was acting.
    private static func openAPSCycleDate(_ cycle: [String: AnyObject], formatter: ISO8601DateFormatter) -> Date? {
        guard let stamp = cycle["deliverAt"] as? String ?? cycle["timestamp"] as? String,
              let date = formatter.date(from: stamp)
        else { return nil }
        return date
    }

    /// Loop's cycle time: the pump clock where there is one, the loop record's
    /// own stamp where there is not. Same fallback as the display path, for the
    /// same reason — some pumps report no clock at all.
    private static func loopCycleDate(_ record: [String: AnyObject], loop: [String: AnyObject], formatter: ISO8601DateFormatter) -> Date? {
        if let clock = (record["pump"] as? [String: AnyObject])?["clock"] as? String,
           let date = formatter.date(from: clock)
        {
            return date
        }
        guard let stamp = loop["timestamp"] as? String, let date = formatter.date(from: stamp) else { return nil }
        return date
    }
}
