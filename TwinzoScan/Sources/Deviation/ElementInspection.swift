import Foundation
import simd

/// Verdict for one BIM element after comparing it against the scan.
enum ElementStatus: String, Codable, Sendable {
    /// Enough of the element was scanned and it sits inside its tolerance.
    case pass
    /// Enough of the element was scanned and it does not.
    case fail
    /// Some returns, but too few to say anything. Reported separately from
    /// `unverified` because "I glimpsed it" and "I never looked" are different
    /// answers to an auditor.
    case insufficientData
    /// No scan returns landed on this element at all.
    case unverified

    var isReportable: Bool { self == .pass || self == .fail }
}

/// Running totals for one element, mergeable across mesh chunks.
///
/// Kept as sums rather than running means so contributions from different mesh
/// anchors can be combined in any order and a retracted anchor can be removed by
/// rebuilding from the survivors, with no accumulated rounding either way.
struct ElementAccumulator: Equatable, Sendable {
    var sampleCount: Int = 0
    var inToleranceCount: Int = 0
    /// Sum of |signed distance|, metres.
    var summedAbsolute: Float = 0
    /// Sum of the model-space surface-to-scan vectors, metres. Divided by
    /// `sampleCount` this is the per-axis offset an inspector reads as dX/dY/dZ.
    var summedDelta: SIMD3<Float> = .zero
    /// Sum of the signed distances, whose mean carries the "is it proud or
    /// recessed overall" answer that a mean of magnitudes destroys.
    var summedSigned: Float = 0
    var maxAbsolute: Float = 0
    /// Worst sample, in LiDAR world space, so the operator can walk back to it.
    var worstWorldPosition: SIMD3<Float> = .zero
    var worstSigned: Float = 0

    /// - Parameters:
    ///   - position: the sample's position, in whatever space `toWorld` maps
    ///     from. ARKit hands vertices out in anchor space, so passing the anchor
    ///     pose here rather than pre-transforming the whole buffer means the
    ///     matrix is applied to the handful of points that turn out to be a
    ///     chunk's worst, not to every vertex of every chunk on every frame.
    mutating func add(signed: Float, delta: SIMD3<Float>, position: SIMD3<Float>,
                      toWorld: float4x4, tolerance: Float) {
        guard signed.isFinite else { return }
        let magnitude = abs(signed)
        sampleCount += 1
        summedAbsolute += magnitude
        summedDelta += delta
        summedSigned += signed
        if magnitude <= tolerance { inToleranceCount += 1 }
        if magnitude > maxAbsolute {
            maxAbsolute = magnitude
            worstWorldPosition = toWorld.transformPoint(position)
            worstSigned = signed
        }
    }

    static func + (lhs: ElementAccumulator, rhs: ElementAccumulator) -> ElementAccumulator {
        var out = ElementAccumulator()
        out.sampleCount = lhs.sampleCount + rhs.sampleCount
        out.inToleranceCount = lhs.inToleranceCount + rhs.inToleranceCount
        out.summedAbsolute = lhs.summedAbsolute + rhs.summedAbsolute
        out.summedDelta = lhs.summedDelta + rhs.summedDelta
        out.summedSigned = lhs.summedSigned + rhs.summedSigned
        if lhs.maxAbsolute >= rhs.maxAbsolute {
            out.maxAbsolute = lhs.maxAbsolute
            out.worstWorldPosition = lhs.worstWorldPosition
            out.worstSigned = lhs.worstSigned
        } else {
            out.maxAbsolute = rhs.maxAbsolute
            out.worstWorldPosition = rhs.worstWorldPosition
            out.worstSigned = rhs.worstSigned
        }
        return out
    }
}

/// A finished per-element result, ready to display, export or upload.
struct ElementInspection: Identifiable, Sendable {
    var element: BIMElement
    var accumulator: ElementAccumulator
    /// Fraction of the element's design surface area that the scan reached.
    /// Nil until a coverage pass has run.
    var coverage: Float?
    /// Threshold this element was judged against, metres.
    var tolerance: Float
    var status: ElementStatus

    var id: UInt32 { element.index }

    /// Mean per-axis offset in model space, metres. The dX/dY/dZ readout.
    var meanOffset: SIMD3<Float> {
        accumulator.sampleCount > 0
            ? accumulator.summedDelta / Float(accumulator.sampleCount)
            : .zero
    }

    /// Mean signed deviation, metres. Positive means the built surface sits
    /// proud of the design surface.
    var meanSigned: Float {
        accumulator.sampleCount > 0
            ? accumulator.summedSigned / Float(accumulator.sampleCount)
            : 0
    }

    var meanAbsolute: Float {
        accumulator.sampleCount > 0
            ? accumulator.summedAbsolute / Float(accumulator.sampleCount)
            : 0
    }

    var maxAbsolute: Float { accumulator.maxAbsolute }

    var passRate: Float {
        accumulator.sampleCount > 0
            ? Float(accumulator.inToleranceCount) / Float(accumulator.sampleCount)
            : 0
    }
}

/// Turns per-vertex GPU output into per-element findings.
///
/// The heat map answers "is something wrong in front of me". This answers "which
/// element, by how much, and in which direction" — the form a finding has to be
/// in before it can go into a report, a BCF issue, or a database row.
///
/// Deliberately free of ARKit and Metal so the aggregation arithmetic can be
/// tested off Apple hardware. Anchors are identified by bare `UUID`.
struct ElementInspectionEngine: Sendable {

    /// Below this many samples an element's numbers are noise, not a measurement.
    /// A handful of vertices clipping the edge of a duct will happily report a
    /// 40 mm mean that is really just the neighbouring wall.
    var minimumSamples: Int = 12

    /// Fraction of design surface that must be reached before an element counts
    /// as measured rather than glimpsed.
    var minimumCoverage: Float = 0.15

    /// Per-anchor contributions, so a retracted or re-meshed anchor can be
    /// replaced without corrupting the totals of the anchors around it.
    private var byAnchor: [UUID: [UInt32: ElementAccumulator]] = [:]

    /// Folds one evaluated mesh chunk in, replacing any earlier contribution
    /// from the same anchor.
    ///
    /// - Parameters:
    ///   - anchorID: the mesh chunk this data came from.
    ///   - elementIndices: per-vertex owning element, from the kernel.
    ///   - signedDistances: per-vertex signed distance, metres.
    ///   - deltas: per-vertex model-space surface-to-scan vectors.
    ///   - positions: per-vertex position, in the space `positionTransform`
    ///     maps to world from.
    ///   - positionTransform: that space's pose. Identity when `positions` are
    ///     already in world space.
    ///   - toleranceFor: threshold to judge each element against. Passed as a
    ///     closure so the caller owns the per-class policy and this type stays
    ///     ignorant of it.
    mutating func ingest(
        anchorID: UUID,
        elementIndices: [UInt32],
        signedDistances: [Float],
        deltas: [SIMD4<Float>],
        positions: [SIMD3<Float>],
        positionTransform: float4x4 = matrix_identity_float4x4,
        toleranceFor: (UInt32) -> Float
    ) {
        let count = min(min(elementIndices.count, signedDistances.count),
                        min(deltas.count, positions.count))
        guard count > 0 else {
            byAnchor.removeValue(forKey: anchorID)
            return
        }

        var chunk: [UInt32: ElementAccumulator] = [:]
        for i in 0..<count {
            let element = elementIndices[i]
            guard element != GPUTriangle.unattributedElement else { continue }
            let signed = signedDistances[i]
            guard signed.isFinite else { continue }

            var accumulator = chunk[element] ?? ElementAccumulator()
            accumulator.add(
                signed: signed,
                delta: deltas[i].xyz,
                position: positions[i],
                toWorld: positionTransform,
                tolerance: toleranceFor(element)
            )
            chunk[element] = accumulator
        }

        if chunk.isEmpty {
            byAnchor.removeValue(forKey: anchorID)
        } else {
            byAnchor[anchorID] = chunk
        }
    }

    mutating func forget(anchorID: UUID) {
        byAnchor.removeValue(forKey: anchorID)
    }

    mutating func removeAll() {
        byAnchor.removeAll()
    }

    var anchorCount: Int { byAnchor.count }

    /// Merged totals across every anchor seen so far.
    func merged() -> [UInt32: ElementAccumulator] {
        var out: [UInt32: ElementAccumulator] = [:]
        for chunk in byAnchor.values {
            for (element, accumulator) in chunk {
                out[element] = (out[element] ?? ElementAccumulator()) + accumulator
            }
        }
        return out
    }

    /// Produces a finding per element, including the elements nothing landed on.
    ///
    /// Unscanned elements are emitted as `.unverified` rather than omitted. An
    /// as-built report that silently drops what it did not look at reads as a
    /// clean bill of health for surfaces nobody inspected, and that is the single
    /// most dangerous way this tool could be wrong.
    ///
    /// - Parameters:
    ///   - elements: the model's full element list.
    ///   - coverage: measured design-surface coverage per element, if a coverage
    ///     pass has run.
    ///   - toleranceFor: threshold per element index.
    func inspections(
        elements: [BIMElement],
        coverage: [UInt32: Float] = [:],
        toleranceFor: (UInt32) -> Float
    ) -> [ElementInspection] {
        let totals = merged()

        return elements.map { element in
            let accumulator = totals[element.index] ?? ElementAccumulator()
            let tolerance = toleranceFor(element.index)
            let elementCoverage = coverage[element.index]

            let status: ElementStatus
            if accumulator.sampleCount == 0 {
                status = .unverified
            } else if accumulator.sampleCount < minimumSamples
                        || (elementCoverage.map { $0 < minimumCoverage } ?? false) {
                status = .insufficientData
            } else if accumulator.maxAbsolute > tolerance {
                status = .fail
            } else {
                status = .pass
            }

            return ElementInspection(
                element: element,
                accumulator: accumulator,
                coverage: elementCoverage,
                tolerance: tolerance,
                status: status
            )
        }
    }
}

/// Whole-model roll-up, the number that goes on the front of a report.
struct InspectionSummary: Equatable, Sendable {
    var pass: Int = 0
    var fail: Int = 0
    var insufficient: Int = 0
    var unverified: Int = 0

    var total: Int { pass + fail + insufficient + unverified }
    /// Elements the scan can actually speak to.
    var measured: Int { pass + fail }

    /// Share of the model that was inspected at all. The honest headline: a 100%
    /// pass rate over 12% of a building is not a passing building.
    var verifiedFraction: Float {
        total > 0 ? Float(measured) / Float(total) : 0
    }

    var passRate: Float {
        measured > 0 ? Float(pass) / Float(measured) : 0
    }

    init() {}

    init(_ inspections: [ElementInspection]) {
        for inspection in inspections {
            switch inspection.status {
            case .pass:             pass += 1
            case .fail:             fail += 1
            case .insufficientData: insufficient += 1
            case .unverified:       unverified += 1
            }
        }
    }
}
