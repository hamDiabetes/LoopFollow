// LoopFollow
// TargetSeries.swift

import Foundation

/// The glucose target the loop is aiming at, over time.
///
/// Steps rather than samples: a target holds until something changes it — a
/// profile segment boundary, a temporary target starting or ending — so the
/// series states only the moments it changed. Most of the chart's slots carry
/// nothing, which is the whole saving on a payload that has 1816 bytes to spend.
///
/// **Read it as the newest step at or before a moment, never as the step at that
/// moment.** A lookup by moment finds nothing almost everywhere and draws a
/// target that blinks in and out; the rule is what turns a handful of changes
/// back into a line.
struct TargetSeries: Codable, Equatable, Hashable {
    /// When the target changed, and what it changed to, in mg/dL. Oldest first.
    struct Step: Codable, Equatable, Hashable {
        let date: Date
        let mgdl: Double

        init(date: Date, mgdl: Double) {
            self.date = date
            self.mgdl = mgdl
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(date.timeIntervalSince1970, forKey: .date)
            try container.encode(mgdl, forKey: .mgdl)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try Date(timeIntervalSince1970: container.decode(Double.self, forKey: .date))
            mgdl = try container.decode(Double.self, forKey: .mgdl)
        }

        private enum CodingKeys: String, CodingKey {
            case date = "d", mgdl = "t"
        }
    }

    let steps: [Step]

    init(steps: [Step]) {
        self.steps = steps.sorted { $0.date < $1.date }
    }

    var isEmpty: Bool { steps.isEmpty }

    /// The target in force at `moment`, or nil where nothing has been stated yet.
    ///
    /// Nil before the first step is the honest answer rather than the first
    /// step's value carried backwards: a series that begins at eight this
    /// morning says nothing about seven, and drawing the line back there would
    /// claim a target nobody published.
    func target(at moment: Date) -> Double? {
        steps.last { $0.date <= moment }?.mgdl
    }

    /// The target as a value per plotted moment, nil where none is stated.
    func values(at moments: [Date]) -> [Double?] {
        moments.map { target(at: $0) }
    }
}

/// A profile's target schedule, as the day's segments.
///
/// The profile states a target per segment of the day and the chart needs one
/// per moment it draws, so the schedule is expanded across the window: a step
/// at the window's start for whatever was in force then, and a step at every
/// boundary the window crosses.
///
/// **A range is not a line.** Where a profile sets `target_low` below
/// `target_high` the loop is aiming at a band, and this chart draws a line, so
/// no series is produced rather than one down the middle of a range nobody
/// stated. This family's profile sets the two equal at every segment, which is
/// why the line exists at all.
struct TargetSchedule: Equatable {
    /// Seconds since local midnight, and the target in mg/dL from then on.
    let segments: [(start: TimeInterval, mgdl: Double)]

    init?(low: [(TimeInterval, Double)], high: [(TimeInterval, Double)]) {
        guard !low.isEmpty, low.count == high.count else { return nil }
        let sortedLow = low.sorted { $0.0 < $1.0 }
        let sortedHigh = high.sorted { $0.0 < $1.0 }
        guard zip(sortedLow, sortedHigh).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) else { return nil }
        segments = sortedLow.map { (start: $0.0, mgdl: $0.1) }
    }

    static func == (lhs: TargetSchedule, rhs: TargetSchedule) -> Bool {
        lhs.segments.count == rhs.segments.count
            && zip(lhs.segments, rhs.segments).allSatisfy { $0.start == $1.start && $0.mgdl == $1.mgdl }
    }

    /// The steps the schedule makes across a window, in the profile's own zone.
    ///
    /// Before the day's first segment the one still running is the last of the
    /// previous day, which is why a window opening at two in the morning starts
    /// on the evening's value rather than on the first entry written.
    func series(from start: Date, to end: Date, timezone: TimeZone) -> TargetSeries {
        guard !segments.isEmpty, start <= end else { return TargetSeries(steps: []) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        var steps: [TargetSeries.Step] = [TargetSeries.Step(date: start, mgdl: inForce(at: start, calendar: calendar))]

        var midnight = calendar.startOfDay(for: start)
        while midnight <= end {
            for segment in segments {
                let boundary = midnight.addingTimeInterval(segment.start)
                if boundary > start, boundary <= end {
                    steps.append(TargetSeries.Step(date: boundary, mgdl: segment.mgdl))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: midnight) else { break }
            midnight = next
        }
        return TargetSeries(steps: steps)
    }

    private func inForce(at moment: Date, calendar: Calendar) -> Double {
        let midnight = calendar.startOfDay(for: moment)
        let seconds = moment.timeIntervalSince(midnight)
        return (segments.last { $0.start <= seconds } ?? segments[segments.count - 1]).mgdl
    }
}
