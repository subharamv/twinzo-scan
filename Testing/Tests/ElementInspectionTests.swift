import XCTest
import simd
@testable import TwinzoCore

/// Per-element aggregation is what turns a heat map into a finding an engineer
/// can act on, so its arithmetic has to survive the messy way ARKit actually
/// delivers data: chunks that overlap elements, chunks that get re-emitted with
/// refined geometry, and chunks that are retracted outright.
final class ElementInspectionTests: XCTestCase {

    private let anchorA = UUID()
    private let anchorB = UUID()

    private func elements(_ count: Int) -> [BIMElement] {
        (0..<count).map { BIMElement.placeholder(index: UInt32($0), name: "E\($0)") }
    }

    /// Feeds one element a uniform offset, which makes every expected statistic
    /// checkable by hand.
    private func ingest(
        into engine: inout ElementInspectionEngine,
        anchor: UUID,
        element: UInt32,
        offset: SIMD3<Float>,
        signed: Float,
        count: Int,
        tolerance: Float = 0.025
    ) {
        engine.ingest(
            anchorID: anchor,
            elementIndices: Array(repeating: element, count: count),
            signedDistances: Array(repeating: signed, count: count),
            deltas: Array(repeating: SIMD4(offset, signed), count: count),
            positions: (0..<count).map { SIMD3(Float($0), 0, 0) },
            toleranceFor: { _ in tolerance }
        )
    }

    // MARK: - The readout

    /// The dX/dY/dZ card in the UI is a mean of the per-vertex offset vectors.
    /// A mean of magnitudes would be a different, and useless, number: a column
    /// leaning 20 mm east reads as "20 mm out" either way, but only the vector
    /// tells the operator which way to shim it.
    func testPerAxisOffsetsAreReported() {
        var engine = ElementInspectionEngine()
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.004, -0.006, 0.018), signed: 0.019, count: 40)

        let inspection = engine.inspections(elements: elements(1)) { _ in 0.025 }[0]

        XCTAssertEqual(inspection.meanOffset.x, 0.004, accuracy: 1e-6)
        XCTAssertEqual(inspection.meanOffset.y, -0.006, accuracy: 1e-6)
        XCTAssertEqual(inspection.meanOffset.z, 0.018, accuracy: 1e-6)
        XCTAssertEqual(inspection.meanSigned, 0.019, accuracy: 1e-6)
        XCTAssertEqual(inspection.status, .pass,
                       "19 mm sits inside a 25 mm tolerance — the direction is worth showing, "
                     + "but it is not a defect")

        // Push the same element past its limit and the verdict flips, without
        // any of the offsets changing meaning.
        var failing = ElementInspectionEngine()
        ingest(into: &failing, anchor: anchorA, element: 0,
               offset: SIMD3(0.004, -0.006, 0.030), signed: 0.031, count: 40)
        XCTAssertEqual(failing.inspections(elements: elements(1)) { _ in 0.025 }[0].status, .fail)
    }

    /// Averaging signed distances and averaging magnitudes answer different
    /// questions. A wall that bows 10 mm in and 10 mm out is 0 mm on average and
    /// 10 mm out everywhere; both numbers have to survive.
    func testSignedAndAbsoluteMeansAreKeptApart() {
        var engine = ElementInspectionEngine()
        engine.ingest(
            anchorID: anchorA,
            elementIndices: [0, 0, 0, 0],
            signedDistances: [0.01, -0.01, 0.01, -0.01],
            deltas: [SIMD4(0, 0.01, 0, 0.01), SIMD4(0, -0.01, 0, -0.01),
                     SIMD4(0, 0.01, 0, 0.01), SIMD4(0, -0.01, 0, -0.01)],
            positions: Array(repeating: SIMD3<Float>.zero, count: 4),
            toleranceFor: { _ in 0.025 }
        )

        let inspection = engine.inspections(elements: elements(1)) { _ in 0.025 }[0]
        XCTAssertEqual(inspection.meanSigned, 0, accuracy: 1e-6)
        XCTAssertEqual(inspection.meanAbsolute, 0.01, accuracy: 1e-6)
        XCTAssertEqual(inspection.maxAbsolute, 0.01, accuracy: 1e-6)
    }

    func testWorstSampleIsKeptForWalkingBackTo() {
        var engine = ElementInspectionEngine()
        engine.ingest(
            anchorID: anchorA,
            elementIndices: [0, 0, 0],
            signedDistances: [0.01, 0.08, 0.02],
            deltas: [SIMD4(0, 0, 0, 0.01), SIMD4(0, 0, 0, 0.08), SIMD4(0, 0, 0, 0.02)],
            positions: [SIMD3(1, 0, 0), SIMD3(2, 3, 4), SIMD3(5, 0, 0)],
            toleranceFor: { _ in 0.025 }
        )

        let accumulator = engine.merged()[0]!
        XCTAssertEqual(accumulator.maxAbsolute, 0.08, accuracy: 1e-6)
        XCTAssertEqual(accumulator.worstWorldPosition, SIMD3(2, 3, 4))
        XCTAssertEqual(accumulator.worstSigned, 0.08, accuracy: 1e-6)
    }

    // MARK: - Anchor churn

    /// ARKit re-emits the same chunk with refined geometry many times a second.
    /// If those accumulated, a slowly-refined wall would climb toward an
    /// arbitrarily large sample count and its statistics would silently become a
    /// function of how long the operator stood still.
    func testReingestingAnAnchorReplacesItsContribution() {
        var engine = ElementInspectionEngine()
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.01, 0, 0), signed: 0.01, count: 30)
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.01, 0, 0), signed: 0.01, count: 30)

        XCTAssertEqual(engine.merged()[0]?.sampleCount, 30)
        XCTAssertEqual(engine.anchorCount, 1)
    }

    func testAnchorsFromDifferentChunksCombine() {
        var engine = ElementInspectionEngine()
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.02, 0, 0), signed: 0.02, count: 10)
        ingest(into: &engine, anchor: anchorB, element: 0,
               offset: SIMD3(0.04, 0, 0), signed: 0.04, count: 30)

        let inspection = engine.inspections(elements: elements(1)) { _ in 0.05 }[0]
        XCTAssertEqual(inspection.accumulator.sampleCount, 40)
        // Weighted by sample count, not a flat average of the two chunks.
        XCTAssertEqual(inspection.meanSigned, 0.035, accuracy: 1e-6)
    }

    func testForgettingAnAnchorRemovesItsContribution() {
        var engine = ElementInspectionEngine()
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.09, 0, 0), signed: 0.09, count: 20)
        ingest(into: &engine, anchor: anchorB, element: 0,
               offset: SIMD3(0.01, 0, 0), signed: 0.01, count: 20)

        engine.forget(anchorID: anchorA)

        let inspection = engine.inspections(elements: elements(1)) { _ in 0.025 }[0]
        XCTAssertEqual(inspection.accumulator.sampleCount, 20)
        XCTAssertEqual(inspection.maxAbsolute, 0.01, accuracy: 1e-6,
                       "A retracted anchor must not leave its worst reading behind")
    }

    // MARK: - Honesty about what was measured

    /// The single most important behaviour here. An element nobody scanned must
    /// never be absent from the report, because an absent element reads as a
    /// passing one.
    func testUnscannedElementsAreReportedAsUnverified() {
        var engine = ElementInspectionEngine()
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.001, 0, 0), signed: 0.001, count: 50)

        let inspections = engine.inspections(elements: elements(3)) { _ in 0.025 }

        XCTAssertEqual(inspections.count, 3)
        XCTAssertEqual(inspections[0].status, .pass)
        XCTAssertEqual(inspections[1].status, .unverified)
        XCTAssertEqual(inspections[2].status, .unverified)

        let summary = InspectionSummary(inspections)
        XCTAssertEqual(summary.pass, 1)
        XCTAssertEqual(summary.unverified, 2)
        XCTAssertEqual(summary.verifiedFraction, 1.0 / 3.0, accuracy: 1e-6)
        XCTAssertEqual(summary.passRate, 1.0, accuracy: 1e-6,
                       "100% of what was measured — which is why the report has to show "
                     + "the verified fraction beside it")
    }

    func testAGlimpsedElementIsNotTreatedAsMeasured() {
        var engine = ElementInspectionEngine()
        engine.minimumSamples = 12
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.2, 0, 0), signed: 0.2, count: 3)

        let inspection = engine.inspections(elements: elements(1)) { _ in 0.025 }[0]
        XCTAssertEqual(inspection.status, .insufficientData,
                       "Three vertices clipping an edge is not a 200 mm defect")
    }

    func testLowCoverageDowngradesAnOtherwisePassingElement() {
        var engine = ElementInspectionEngine()
        engine.minimumCoverage = 0.15
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.001, 0, 0), signed: 0.001, count: 100)

        let full = engine.inspections(elements: elements(1), coverage: [0: 0.9]) { _ in 0.025 }[0]
        XCTAssertEqual(full.status, .pass)

        let sliver = engine.inspections(elements: elements(1), coverage: [0: 0.04]) { _ in 0.025 }[0]
        XCTAssertEqual(sliver.status, .insufficientData,
                       "A clean reading over 4% of a wall is not a verdict on the wall")
    }

    // MARK: - Robustness

    /// Vertices with no BIM surface nearby come back as NaN and as the sentinel
    /// element index. Both are clutter — furniture, people, scan noise — and
    /// letting either into an element's totals invents defects.
    func testUnattributedAndNonFiniteSamplesAreIgnored() {
        var engine = ElementInspectionEngine()
        engine.ingest(
            anchorID: anchorA,
            elementIndices: [0, GPUTriangle.unattributedElement, 0],
            signedDistances: [0.01, 0.5, .nan],
            deltas: [SIMD4(0, 0, 0.01, 0.01), SIMD4(0, 0, 0.5, 0.5), SIMD4(repeating: .nan)],
            positions: Array(repeating: SIMD3<Float>.zero, count: 3),
            toleranceFor: { _ in 0.025 }
        )

        let accumulator = engine.merged()[0]
        XCTAssertEqual(accumulator?.sampleCount, 1)
        XCTAssertEqual(accumulator?.maxAbsolute ?? 0, 0.01, accuracy: 1e-6)
    }

    /// The buffers all come from the same dispatch and should always agree, but
    /// a mismatch must truncate rather than trap: crashing an inspector's device
    /// mid-walkthrough loses the whole scan.
    func testMismatchedBufferLengthsTruncateRatherThanCrash() {
        var engine = ElementInspectionEngine()
        engine.ingest(
            anchorID: anchorA,
            elementIndices: [0, 0, 0],
            signedDistances: [0.01],
            deltas: [SIMD4(0, 0, 0.01, 0.01), SIMD4(0, 0, 0.01, 0.01)],
            positions: [SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 0, 0)],
            toleranceFor: { _ in 0.025 }
        )
        XCTAssertEqual(engine.merged()[0]?.sampleCount, 1)
    }

    func testPerElementTolerancePolicyIsHonoured() {
        var engine = ElementInspectionEngine()
        // Same 30 mm deviation on both elements.
        ingest(into: &engine, anchor: anchorA, element: 0,
               offset: SIMD3(0.03, 0, 0), signed: 0.03, count: 40, tolerance: 0.025)
        ingest(into: &engine, anchor: anchorB, element: 1,
               offset: SIMD3(0.03, 0, 0), signed: 0.03, count: 40, tolerance: 0.050)

        // Element 0 is structural (25 mm), element 1 is MEP (50 mm).
        let inspections = engine.inspections(elements: elements(2)) { index in
            index == 0 ? 0.025 : 0.050
        }
        XCTAssertEqual(inspections[0].status, .fail)
        XCTAssertEqual(inspections[1].status, .pass)
    }

    func testToleranceClassInferenceFavoursTheSpecificTerm() {
        // "Curtain Wall" contains "wall"; grading it as structural would hold a
        // facade to a tolerance it is never expected to meet.
        XCTAssertEqual(ToleranceClass.inferred(ifcType: "IfcCurtainWall", category: nil), .finishes)
        XCTAssertEqual(ToleranceClass.inferred(ifcType: "IfcColumn", category: nil), .structural)
        XCTAssertEqual(ToleranceClass.inferred(ifcType: "IfcDuctSegment", category: nil), .mep)
        XCTAssertEqual(ToleranceClass.inferred(ifcType: nil, category: nil), .unclassified)
    }

    /// A guessed IfcGUID files a defect against someone else's column, so a node
    /// name that merely looks like one must never become an identifier.
    func testNodeNameParsingNeverInventsAnIdentifier() {
        let parsed = BIMNodeName.parse("IfcColumn_C-12_1aBc0De7F9gHiJkLmNoPqR")
        XCTAssertEqual(parsed.ifcType, "IfcColumn")
        XCTAssertTrue(parsed.label.contains("C-12"))
        XCTAssertNotNil(parsed.guidLike)

        let element = BIMElement.placeholder(index: 0, name: parsed.label)
        XCTAssertFalse(element.isAddressable)
    }
}
