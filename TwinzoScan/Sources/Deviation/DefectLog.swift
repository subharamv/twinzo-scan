import Foundation
import ARKit
import simd

/// One recorded deviation worth an inspector's attention.
struct Defect: Identifiable {
    let id = UUID()
    /// Where it is, in LiDAR world space — enough to walk back to it.
    var worldPosition: SIMD3<Float>
    /// Signed distance to the design surface. Positive means material sits
    /// closer to the scanner than designed.
    var signedDeviation: Float
    var anchorID: UUID
    var recordedAt: Date

    var magnitudeMillimetres: Float { abs(signedDeviation) * 1000 }
    var isProud: Bool { signedDeviation > 0 }
}

/// Keeps the worst deviation found in each mesh chunk.
///
/// The heat map answers "is anything wrong here"; this answers "what were the
/// ten worst things in the whole bay, and where do I stand to see them". Keeping
/// one entry per anchor rather than a global top-N stops a single badly-placed
/// column from filling the list with a hundred samples of itself — mesh chunks
/// are roughly room-scale, so one worst point per chunk spreads the report over
/// the actual space.
@MainActor
final class DefectLog: ObservableObject {

    @Published private(set) var defects: [Defect] = []

    /// Deviations smaller than this are not worth logging even when out of
    /// tolerance; they are noise at LiDAR's accuracy.
    private let floorMillimetres: Float = 5

    private var worstByAnchor: [UUID: Defect] = [:]

    /// Folds one evaluated chunk into the log.
    ///
    /// - Parameters:
    ///   - field: GPU results for this anchor.
    ///   - anchor: the chunk, used for its pose and identity.
    ///   - positions: that chunk's vertices in anchor space. Passed in rather
    ///     than re-read from the anchor: the caller has already paid for this
    ///     copy and it is one of the more expensive things in the frame.
    ///   - tolerance: current pass/fail threshold in metres.
    func record(field: DeviationField, anchor: ARMeshAnchor,
                positions: [SIMD3<Float>], tolerance: Float) {
        guard positions.count == field.signedDistances.count else { return }

        var worstIndex = -1
        var worstMagnitude = max(tolerance, floorMillimetres / 1000)

        for i in 0..<field.signedDistances.count {
            let d = field.signedDistances[i]
            // NaN marks a vertex with no corresponding BIM surface. It is
            // clutter, not a defect, and NaN comparisons are false anyway.
            guard d.isFinite else { continue }
            if abs(d) > worstMagnitude {
                worstMagnitude = abs(d)
                worstIndex = i
            }
        }

        if worstIndex < 0 {
            // This chunk is clean now. Retract any defect previously logged for
            // it, so a fixed problem stops being reported.
            if worstByAnchor.removeValue(forKey: anchor.identifier) != nil { publish() }
            return
        }

        worstByAnchor[anchor.identifier] = Defect(
            worldPosition: anchor.transform.transformPoint(positions[worstIndex]),
            signedDeviation: field.signedDistances[worstIndex],
            anchorID: anchor.identifier,
            recordedAt: Date()
        )
        publish()
    }

    func forget(anchorID: UUID) {
        if worstByAnchor.removeValue(forKey: anchorID) != nil { publish() }
    }

    func removeAll() {
        worstByAnchor.removeAll()
        defects = []
    }

    /// Comma-separated export for handing findings to a defect tracker or back
    /// to the twin backend. Coordinates are in the AR session's world frame;
    /// they need the same alignment applied to become model coordinates.
    func exportCSV(worldToModel: float4x4) -> String {
        var lines = ["model_x,model_y,model_z,deviation_mm,direction,recorded_at"]
        let formatter = ISO8601DateFormatter()
        for defect in defects {
            let p = worldToModel.transformPoint(defect.worldPosition)
            lines.append(String(
                format: "%.4f,%.4f,%.4f,%.1f,%@,%@",
                p.x, p.y, p.z,
                defect.magnitudeMillimetres,
                defect.isProud ? "proud" : "recessed",
                formatter.string(from: defect.recordedAt)))
        }
        return lines.joined(separator: "\n")
    }

    private func publish() {
        defects = worstByAnchor.values.sorted {
            abs($0.signedDeviation) > abs($1.signedDeviation)
        }
    }
}
