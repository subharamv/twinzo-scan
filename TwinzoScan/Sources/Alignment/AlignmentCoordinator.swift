import Foundation
import simd

/// Where the BIM model currently sits relative to the scanned world, and how
/// much that placement can be trusted.
enum AlignmentState: Equatable {
    /// No model loaded yet.
    case waitingForModel
    /// Operator is placing the model by hand. Deviation analysis stays off:
    /// numbers from an unrefined pose would be meaningless.
    case placing
    /// ICP is running on a background queue.
    case refining
    /// Registered. Deviation analysis is live.
    case aligned(rmsError: Float, inlierRatio: Float)
    /// ICP ran but the fit is not trustworthy.
    case failed(reason: String)

    var allowsDeviationAnalysis: Bool {
        if case .aligned = self { return true }
        return false
    }
}

/// Owns the LiDAR-world <-> BIM-model transform and the workflow that produces it.
///
/// The two-stage design is deliberate. Point-to-plane ICP is a local optimiser:
/// dropped into a factory of near-identical bays with no prior, it will happily
/// converge one bay off and report an excellent residual. So the operator
/// establishes a coarse pose first — by hand or from a surveyed reference — and
/// ICP only ever refines from there.
@MainActor
final class AlignmentCoordinator: ObservableObject {

    @Published private(set) var state: AlignmentState = .waitingForModel
    /// BIM model space -> LiDAR world space. This is what the rendered model uses.
    @Published private(set) var modelToWorld: float4x4 = matrix_identity_float4x4

    /// LiDAR world space -> BIM model space. What the deviation kernel and ICP need.
    var worldToModel: float4x4 { modelToWorld.inverse }

    // Coarse placement is stored as its components rather than a raw matrix so
    // gestures compose cleanly and rounding does not accumulate in the matrix.
    private var placementPosition: SIMD3<Float> = .zero
    private var placementYaw: Float = 0

    private let icpQueue = DispatchQueue(label: "com.twinzo.scan.icp", qos: .userInitiated)

    // MARK: - Coarse placement

    func modelDidLoad() {
        state = .placing
        placementPosition = .zero
        placementYaw = 0
        rebuildTransform()
    }

    func reset() {
        state = .placing
        placementPosition = .zero
        placementYaw = 0
        rebuildTransform()
    }

    /// Drops the model's origin at a raycast hit, typically a tap on the floor.
    func place(at position: SIMD3<Float>) {
        placementPosition = position
        state = .placing
        rebuildTransform()
    }

    /// Rotate about the gravity axis. Wired to a two-finger rotation gesture.
    func rotate(byRadians delta: Float) {
        placementYaw += delta
        state = .placing
        rebuildTransform()
    }

    /// Translate in the horizontal plane, in world axes. Wired to a pan gesture.
    func nudge(x: Float, z: Float) {
        placementPosition.x += x
        placementPosition.z += z
        state = .placing
        rebuildTransform()
    }

    /// Raise or lower the model. Needed when the scan floor and the model's datum
    /// disagree, which they usually do — BIM levels are rarely at ARKit's origin.
    func adjustHeight(by delta: Float) {
        placementPosition.y += delta
        state = .placing
        rebuildTransform()
    }

    /// Roll and pitch are deliberately not adjustable. ARKit's world origin is
    /// gravity-aligned and so is the BIM model, so the only genuinely unknown
    /// rotation at placement time is heading. Letting an operator tilt the model
    /// by hand mostly introduces error that ICP then has to undo.
    private func rebuildTransform() {
        let rotation = simd_quatf(angle: placementYaw, axis: SIMD3<Float>(0, 1, 0))
        var matrix = float4x4(simd_float3x3(rotation))
        matrix.columns.3 = SIMD4<Float>(placementPosition, 1)
        modelToWorld = matrix
    }

    // MARK: - Refinement

    /// Runs ICP against the accumulated scan.
    ///
    /// Two passes: a generous correspondence radius to absorb coarse placement
    /// error, then a tight one to settle. Running only the tight pass strands a
    /// hand-placed model; running only the loose one leaves millimetres on the table.
    ///
    /// - Parameter points: downsampled scan cloud in LiDAR world space.
    func refine(using points: [SIMD3<Float>], mesh: BVH) {
        guard !points.isEmpty, !mesh.isEmpty else {
            state = .failed(reason: "Scan more of the space before aligning.")
            return
        }
        // Ignore re-entry: ICP over a full scan takes long enough that an
        // impatient double-tap would otherwise queue a second run against a
        // stale initial pose.
        if case .refining = state { return }
        state = .refining

        let initial = worldToModel
        icpQueue.async { [weak self] in
            let coarse = PointToPlaneICP.align(
                points: points, to: mesh, initial: initial, parameters: .coarse
            )
            let fine = PointToPlaneICP.align(
                points: points, to: mesh, initial: coarse.worldToModel, parameters: .fine
            )
            Task { @MainActor [weak self] in
                self?.applyRefinement(fine)
            }
        }
    }

    /// Accept-or-reject thresholds. These are the difference between a tool an
    /// inspector trusts and one that confidently reports nonsense.
    private struct AcceptanceCriteria {
        /// Beyond this residual the "alignment" is not describing the same surface.
        static let maximumRMS: Float = 0.08
        /// Too few correspondences means the model was fitted to a fragment of
        /// the scan and the pose is unconstrained in at least one axis.
        static let minimumInlierRatio: Float = 0.35
    }

    private func applyRefinement(_ result: ICPResult) {
        guard result.rmsError.isFinite else {
            state = .failed(reason: "ICP found no correspondences. Check the coarse placement.")
            return
        }
        guard result.inlierRatio >= AcceptanceCriteria.minimumInlierRatio else {
            state = .failed(reason: String(
                format: "Only %.0f%% of the scan matched the model. Place it closer, or scan more of the space.",
                result.inlierRatio * 100))
            return
        }
        guard result.rmsError <= AcceptanceCriteria.maximumRMS else {
            state = .failed(reason: String(
                format: "Residual %.0f mm is too high to trust. The model may be in the wrong bay.",
                result.rmsError * 1000))
            return
        }

        modelToWorld = result.worldToModel.inverse
        // Keep the placement components in step so a later manual nudge starts
        // from the refined pose rather than snapping back to the hand placement.
        placementPosition = modelToWorld.translation
        placementYaw = modelToWorld.yawAboutGravity
        state = .aligned(rmsError: result.rmsError, inlierRatio: result.inlierRatio)
    }
}

extension float4x4 {
    init(_ rotation: simd_float3x3) {
        self.init(
            SIMD4(rotation.columns.0, 0),
            SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    /// Heading extracted by projecting the model's local X axis onto the ground
    /// plane. Valid because placement keeps the model gravity-aligned.
    var yawAboutGravity: Float {
        let forward = columns.0
        return atan2(-forward.z, forward.x)
    }
}
