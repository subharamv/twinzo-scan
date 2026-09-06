import Foundation

/// Aggregate deviation figures for one mesh chunk or one whole frame.
///
/// Deliberately free of Metal and ARKit imports so it can be unit tested off
/// Apple hardware — the merge below is weighted arithmetic, which is exactly the
/// kind of thing that goes wrong quietly and produces numbers that still look
/// reasonable on screen.
struct DeviationStatistics: Equatable {
    var inToleranceCount: Int = 0
    var outOfToleranceCount: Int = 0
    var unmatchedCount: Int = 0
    /// Mean of the absolute deviation over compared vertices, in metres.
    var meanDeviation: Float = 0
    var maxDeviation: Float = 0

    /// Vertices that had a corresponding BIM surface. Unmatched ones are
    /// excluded: they are clutter, not a pass or a fail.
    var comparedCount: Int { inToleranceCount + outOfToleranceCount }

    var passRate: Float {
        comparedCount > 0 ? Float(inToleranceCount) / Float(comparedCount) : 0
    }

    /// Merges two chunks' figures.
    ///
    /// The mean is weighted by compared vertex count, not averaged directly: a
    /// chunk covering ten vertices must not pull the frame's mean as hard as one
    /// covering ten thousand.
    static func + (lhs: DeviationStatistics, rhs: DeviationStatistics) -> DeviationStatistics {
        var out = DeviationStatistics()
        out.inToleranceCount = lhs.inToleranceCount + rhs.inToleranceCount
        out.outOfToleranceCount = lhs.outOfToleranceCount + rhs.outOfToleranceCount
        out.unmatchedCount = lhs.unmatchedCount + rhs.unmatchedCount
        out.maxDeviation = max(lhs.maxDeviation, rhs.maxDeviation)

        let lw = Float(lhs.comparedCount)
        let rw = Float(rhs.comparedCount)
        if lw == 0 {
            // Short-circuit rather than computing (x*0 + y*w)/w. The frame total
            // is built with reduce(DeviationStatistics(), +), so an empty operand
            // is the common case, and the redundant multiply-divide round trip
            // costs a rounding step on every single accumulation.
            out.meanDeviation = rhs.meanDeviation
        } else if rw == 0 {
            out.meanDeviation = lhs.meanDeviation
        } else {
            out.meanDeviation = (lhs.meanDeviation * lw + rhs.meanDeviation * rw) / (lw + rw)
        }
        return out
    }
}

/// Inspection thresholds, in metres.
///
/// Exposed in the UI rather than hard-coded because a single tolerance is never
/// right across a whole building: structural steel, MEP routing and
/// architectural finishes are signed off against very different limits.
struct ToleranceSettings: Equatable {
    /// Pass/fail line.
    var tolerance: Float = 0.025
    /// Deviation at which the heat ramp saturates.
    var saturation: Float = 0.150
    /// Beyond this, surface is treated as clutter rather than as a defect.
    var rejection: Float = 0.600

    /// The thresholds must stay ordered or the banding degenerates: a saturation
    /// below tolerance collapses the ramp, and a rejection below saturation
    /// hides the very defects the ramp is meant to show.
    var isCoherent: Bool {
        tolerance > 0 && tolerance < saturation && saturation < rejection
    }

    /// Reorders the thresholds if a slider has pushed them out of sequence.
    /// The UI exposes three independent sliders, so an operator can easily set a
    /// 100 mm pass line against a 50 mm saturation point; left alone that makes
    /// every failing vertex jump straight to the most severe band.
    func normalized() -> ToleranceSettings {
        var out = self
        out.tolerance = max(0.001, tolerance)
        out.saturation = max(out.tolerance * 1.5, saturation)
        out.rejection = max(out.saturation * 1.5, rejection)
        return out
    }

    static let structural = ToleranceSettings(tolerance: 0.025, saturation: 0.150)
    static let mep = ToleranceSettings(tolerance: 0.050, saturation: 0.250)
    static let finishes = ToleranceSettings(tolerance: 0.010, saturation: 0.060)
}
