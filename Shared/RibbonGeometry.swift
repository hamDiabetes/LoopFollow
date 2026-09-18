// LoopFollow
// RibbonGeometry.swift

import Foundation

/// Where a ribbon's edges land, as arithmetic rather than as a render.
///
/// **Extracted so it can be tested at all.** All of it used to live in a local
/// function nested inside a computed property of `WidgetChartView`, where
/// nothing outside a running render could call it — and a suite of 193 cases
/// stayed green while the height setting was deleted from the formula, while the
/// ribbon moved to the other side of the trace, and while the floor clamp was
/// removed entirely. Those were not four missed tests. They were one region no
/// test could enter.
///
/// The precedent is `RibbonBaseline.runs`, pulled out of the same view for the
/// same reason and tested ever since. Nothing here changes a pixel.
enum RibbonGeometry {
    /// How much wider the vertical offset has to be for the band to read at its
    /// intended width where the trace is sloped.
    ///
    /// The offset is vertical; what the eye measures is across the band. On a
    /// flat stretch those are the same and on a slope they are not, which is
    /// what "it loses its width when it rises" describes. Measured against the
    /// harness's constant-figure ramp: 48 px vertical drew 38.9 px across at
    /// 37° and 35.7 px at 42°, against 0.799 and 0.743 for the cosine.
    ///
    /// **Capped at 2.0, which binds on real data rather than only in theory.**
    /// Across 598 readings, 4.4% of lock-screen segments and about a fifth of
    /// six-hour widget ones are steeper than 60°. Past the cap the band is
    /// exactly twice the width it is drawn at today and it narrows again from
    /// there — worse than correct, better than now, at every angle. The cap is
    /// what keeps a near-vertical segment from taking the card: uncapped, the
    /// steepest reading measured asks for 3.46 times the height.
    static let maxWidthCompensation: Double = 2

    static func widthCompensation(screenSlope: Double) -> Double {
        min((1 + screenSlope * screenSlope).squareRoot(), maxWidthCompensation)
    }

    /// The two edges of one sample's ribbon, in display units.
    ///
    /// `near` is the edge against the glucose trace and `far` carries the
    /// magnitude. A sample with no thickness sits on the trace rather than a gap
    /// off it: it is one of the flat ends a run tapers through, and it has to
    /// meet the line the ribbon is measured against.
    ///
    /// `screenSlope` is the trace's local slope in points per point, so the
    /// compensation can be computed where the drawing happens rather than in
    /// glucose units, which carry no aspect. An `AreaMark` is a function of x,
    /// so a true parallel band cannot be expressed; widening the vertical offset
    /// until the perpendicular width comes out right is the standard substitute.
    static func edges(
        line: Double,
        share: Double,
        span: Double,
        above: Bool,
        gap: Double,
        floor: Double?,
        screenSlope: Double = 0
    ) -> (near: Double, far: Double) {
        let lift = share > 0 ? gap * span : 0
        let near = above ? line + lift : line - lift
        let offset = share * span * widthCompensation(screenSlope: screenSlope)
        var far = above ? near + offset : near - offset
        if let floor, far < floor { far = min(near, floor) }
        return (near, far)
    }

    /// Where the hairline sits: a gap off the trace whatever the magnitude, so a
    /// series reporting zero still has a mark of its own rather than one hidden
    /// under the glucose line.
    static func baselineEdge(line: Double, span: Double, above: Bool, gap: Double) -> Double {
        above ? line + gap * span : line - gap * span
    }
}

extension InsulinRibbonPlacement {
    var isAbove: Bool { self == .above }

    /// The depth the insulin ribbon may not pass, or nil where it runs as deep
    /// as the insulin takes it.
    ///
    /// Nil for both below cases that ship: Justin chose unclipped by looking at
    /// it, because what he wants to see during a low is how much insulin is
    /// still working, and that is what a floor at the low line removed.
    func floor(low: Double) -> Double? {
        self == .belowClipped ? low : nil
    }
}
