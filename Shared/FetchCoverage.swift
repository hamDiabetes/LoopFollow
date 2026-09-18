// LoopFollow
// FetchCoverage.swift

import Foundation

/// How far back a capped query actually establishes anything.
///
/// Nightscout answers newest first and stops at `count`, so a response holding
/// as many records as it asked for may have been cut off, and the window it was
/// asked about is wider than the window it can speak for.
///
/// **Nil here means "not truncated", which is the opposite of "unknown", and
/// the difference has bitten once already.** `TreatmentRibbons.coveredFrom` is
/// read as *nobody stated a bound*, so passing this nil straight into it said
/// the query covered everything, including hours it never asked about — which
/// is fine for a ribbon, whose data simply is not there, and wrong for any mark
/// that means "the chart knows this stretch", because it would claim knowledge
/// of a window nobody described.
///
/// So the rule for a producer using this: **if you know the window you asked
/// for, state it.** Fall back to the window's own start when this returns nil,
/// and leave `coveredFrom` nil only where nothing knows the extent — a payload
/// from a relay that does not say, for instance. Nil then means one thing
/// everywhere: nobody said.
enum FetchCoverage {
    /// The oldest moment the answer covers, or nil when the whole window does.
    ///
    /// Truncation is counted in records and the bound is read from the dates,
    /// because they are different questions: a record the caller could not date
    /// still proves the query read that far back.
    ///
    /// `now` is what a full answer covers when not one of its records could be
    /// dated — nothing it established can be placed in time.
    static func bound(records: Int, dates: [Date], asked count: Int, now: Date = Date()) -> Date? {
        guard records >= count else { return nil }
        return dates.min() ?? now
    }

    /// The oldest moment several queries jointly cover.
    ///
    /// The latest of the bounds rather than the earliest: a stretch is only
    /// described where every query describes it, and one that was cut off says
    /// nothing about what the others found.
    static func bound(of bounds: [Date?]) -> Date? {
        bounds.compactMap { $0 }.max()
    }
}
