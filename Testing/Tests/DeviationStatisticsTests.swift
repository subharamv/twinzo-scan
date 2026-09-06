import XCTest
@testable import TwinzoCore

/// These figures are what an inspector reads off the screen and puts in a
/// report, so the arithmetic behind them is worth pinning down. The merge in
/// particular ran untested until now — it was moved out of `DeviationEngine`
/// precisely so it could be reached without a Metal device, and the move
/// immediately exposed a missing `return`.
final class DeviationStatisticsTests: XCTestCase {

    // MARK: - Merging chunks

    func testMergeSumsCounts() {
        let a = DeviationStatistics(inToleranceCount: 10, outOfToleranceCount: 2,
                                    unmatchedCount: 3, meanDeviation: 0.01, maxDeviation: 0.05)
        let b = DeviationStatistics(inToleranceCount: 5, outOfToleranceCount: 1,
                                    unmatchedCount: 7, meanDeviation: 0.02, maxDeviation: 0.03)
        let sum = a + b

        XCTAssertEqual(sum.inToleranceCount, 15)
        XCTAssertEqual(sum.outOfToleranceCount, 3)
        XCTAssertEqual(sum.unmatchedCount, 10)
        XCTAssertEqual(sum.comparedCount, 18)
    }

    func testMergeTakesTheLargerMaximum() {
        let a = DeviationStatistics(inToleranceCount: 1, maxDeviation: 0.08)
        let b = DeviationStatistics(inToleranceCount: 1, maxDeviation: 0.02)
        XCTAssertEqual((a + b).maxDeviation, 0.08, accuracy: 1e-6)
        XCTAssertEqual((b + a).maxDeviation, 0.08, accuracy: 1e-6)
    }

    func testMeanIsWeightedByComparedCount() {
        // A ten-vertex chunk must not pull the frame mean as hard as a
        // ten-thousand-vertex one. A naive average would give 55 mm here.
        let small = DeviationStatistics(inToleranceCount: 10, meanDeviation: 0.100)
        let large = DeviationStatistics(inToleranceCount: 990, meanDeviation: 0.010)

        let merged = small + large
        let expected: Float = (0.100 * 10 + 0.010 * 990) / 1000
        XCTAssertEqual(merged.meanDeviation, expected, accuracy: 1e-6)
        XCTAssertLessThan(merged.meanDeviation, 0.012, "Small chunk dominated the mean")
    }

    func testMergeIsOrderIndependent() {
        let a = DeviationStatistics(inToleranceCount: 7, outOfToleranceCount: 3,
                                    meanDeviation: 0.04, maxDeviation: 0.09)
        let b = DeviationStatistics(inToleranceCount: 50, outOfToleranceCount: 5,
                                    meanDeviation: 0.01, maxDeviation: 0.02)
        XCTAssertEqual((a + b).meanDeviation, (b + a).meanDeviation, accuracy: 1e-6)
        XCTAssertEqual(a + b, b + a)
    }

    func testMergingWithAnEmptyChunkChangesNothing() {
        // This is how the per-frame total is built: reduce from a zero value.
        let a = DeviationStatistics(inToleranceCount: 4, outOfToleranceCount: 1,
                                    meanDeviation: 0.03, maxDeviation: 0.07)
        XCTAssertEqual(a + DeviationStatistics(), a)
    }

    func testReduceOverManyChunksMatchesADirectMean() {
        // The real accumulation path in ScanSession.
        let chunks = (1...20).map { i in
            DeviationStatistics(inToleranceCount: i * 10,
                                meanDeviation: Float(i) * 0.001)
        }
        let merged = chunks.reduce(DeviationStatistics(), +)

        var weighted: Float = 0
        var total: Float = 0
        for c in chunks {
            weighted += c.meanDeviation * Float(c.comparedCount)
            total += Float(c.comparedCount)
        }
        XCTAssertEqual(merged.meanDeviation, weighted / total, accuracy: 1e-5)
        XCTAssertEqual(merged.comparedCount, chunks.reduce(0) { $0 + $1.comparedCount })
    }

    // MARK: - Pass rate

    func testPassRateIgnoresUnmatchedSurface() {
        // Clutter is neither a pass nor a fail. Counting it either way would make
        // the headline number depend on how much furniture is in the room.
        let stats = DeviationStatistics(inToleranceCount: 90, outOfToleranceCount: 10,
                                        unmatchedCount: 100_000)
        XCTAssertEqual(stats.passRate, 0.9, accuracy: 1e-6)
    }

    func testPassRateOfNothingIsZeroNotNaN() {
        // Displayed every frame before the first chunk is evaluated; NaN here
        // would render as "nan%".
        let stats = DeviationStatistics()
        XCTAssertEqual(stats.passRate, 0)
        XCTAssertFalse(stats.passRate.isNaN)
    }

    // MARK: - Tolerance coherence

    func testDefaultsAreCoherent() {
        XCTAssertTrue(ToleranceSettings().isCoherent)
        XCTAssertTrue(ToleranceSettings.structural.normalized().isCoherent)
        XCTAssertTrue(ToleranceSettings.mep.normalized().isCoherent)
        XCTAssertTrue(ToleranceSettings.finishes.normalized().isCoherent)
    }

    func testNormalizationFixesInvertedThresholds() {
        // Reachable from the UI: three independent sliders, no cross-constraint.
        let broken = ToleranceSettings(tolerance: 0.100, saturation: 0.050, rejection: 0.020)
        XCTAssertFalse(broken.isCoherent)

        let fixed = broken.normalized()
        XCTAssertTrue(fixed.isCoherent)
        XCTAssertEqual(fixed.tolerance, 0.100, accuracy: 1e-6,
                       "Normalization should preserve the operator's pass/fail line")
        XCTAssertGreaterThan(fixed.saturation, fixed.tolerance)
        XCTAssertGreaterThan(fixed.rejection, fixed.saturation)
    }

    func testNormalizationIsIdempotent() {
        // ScanSession re-assigns the normalised value back through didSet, which
        // re-enters exactly once. A non-idempotent normalisation would loop.
        let once = ToleranceSettings(tolerance: 0.09, saturation: 0.02, rejection: 0.01).normalized()
        XCTAssertEqual(once, once.normalized())
    }

    func testNormalizationRejectsNonPositiveTolerance() {
        let fixed = ToleranceSettings(tolerance: 0, saturation: 0, rejection: 0).normalized()
        XCTAssertTrue(fixed.isCoherent)
        XCTAssertGreaterThan(fixed.tolerance, 0)
    }
}
