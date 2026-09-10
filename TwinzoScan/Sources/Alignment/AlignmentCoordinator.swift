import Foundation
import Combine
import simd

/// Everything known about the quality of the current registration.
struct AlignmentQuality: Equatable, Sendable {
    var rmsError: Float
    var inlierRatio: Float
    var method: AlignmentMethod
    var scale: Float
    var establishedAt: Date
    /// Degrees of freedom the fit actually determined, when it came from targets.
    var degreesOfFreedom: RegistrationFit.DegreesOfFreedom?

    static func == (lhs: AlignmentQuality, rhs: AlignmentQuality) -> Bool {
        lhs.rmsError == rhs.rmsError && lhs.inlierRatio == rhs.inlierRatio
            && lhs.method == rhs.method && lhs.scale == rhs.scale
            && lhs.establishedAt == rhs.establishedAt
            && lhs.degreesOfFreedom == rhs.degreesOfFreedom
    }
}

/// Where the BIM model currently sits relative to the scanned world, and how
/// much that placement can be trusted.
enum AlignmentState: Equatable {
    /// No model loaded yet.
    case waitingForModel
    /// Operator is placing the model by hand or dropping targets. Deviation
    /// analysis stays off: numbers from an unrefined pose would be meaningless.
    case placing
    /// A fit is running on a background queue.
    case refining
    /// Registered. Deviation analysis is live.
    case aligned(AlignmentQuality)
    /// Registered, but tracking has moved underneath us by more than the
    /// registration's own accuracy. Analysis continues — stopping it mid-walk
    /// would be worse — but every finding taken from here is suspect and the
    /// operator is told so.
    case drifting(AlignmentQuality, driftMeters: Float)
    /// A fit ran but is not trustworthy.
    case failed(reason: String)

    var allowsDeviationAnalysis: Bool {
        switch self {
        case .aligned, .drifting: return true
        default: return false
        }
    }

    var quality: AlignmentQuality? {
        switch self {
        case .aligned(let quality):      return quality
        case .drifting(let quality, _):  return quality
        default:                         return nil
        }
    }
}

/// One drift measurement, kept as a series so the trend is visible rather than
/// only the latest value.
struct DriftSample: Identifiable, Sendable {
    let id = UUID()
    var timestamp: Date
    /// How far the correcting transform would move a point at working distance.
    var displacementMeters: Float
    /// Residual of the check fit.
    var rmsError: Float
    var corrected: Bool
}

/// Owns the LiDAR-world <-> BIM-model transform and the workflow that produces it.
///
/// The staged design is deliberate. Point-to-plane ICP is a local optimiser:
/// dropped into a factory of near-identical bays with no prior, it will happily
/// converge one bay off and report an excellent residual. So a coarse pose is
/// established first — by hand, or from surveyed targets — and ICP only ever
/// refines from there.
///
/// Registration is also not a one-time event. ARKit's world frame drifts over a
/// long walkthrough, and a transform that was right at the start of an
/// inspection is quietly wrong by the end. `checkForDrift` re-measures it on a
/// cadence and either corrects it or says so.
@MainActor
final class AlignmentCoordinator: ObservableObject {

    @Published private(set) var state: AlignmentState = .waitingForModel
    /// BIM model space -> LiDAR world space. This is what the rendered model uses.
    @Published private(set) var modelToWorld: float4x4 = matrix_identity_float4x4
    /// Surveyed correspondences the operator has dropped.
    @Published private(set) var controlPoints: [ControlPointPair] = []
    /// Most recent drift measurements, newest last.
    @Published private(set) var driftHistory: [DriftSample] = []
    /// Warnings from the most recent target fit, surfaced verbatim.
    @Published private(set) var registrationWarnings: [String] = []

    /// LiDAR world space -> BIM model space. What the deviation kernel and ICP need.
    var worldToModel: float4x4 { modelToWorld.inverse }

    /// Uniform scale currently applied to the model. Held separately because a
    /// scale that is not 1.0 makes every deviation figure a percentage of the
    /// truth, and the operator has to be able to see it.
    private(set) var appliedScale: Float = 1

    // Coarse placement is stored as components rather than a raw matrix so
    // gestures compose cleanly and rounding does not accumulate in the matrix.
    private var placementPosition: SIMD3<Float> = .zero
    private var placementRotation: simd_float3x3 = matrix_identity_float3x3
    private var placementScale: Float = 1

    private let icpQueue = DispatchQueue(label: "com.twinzo.scan.icp", qos: .userInitiated)
    private var isCheckingDrift = false

    // MARK: - Coarse placement

    func modelDidLoad() {
        state = .placing
        resetComponents()
        controlPoints.removeAll()
        driftHistory.removeAll()
        registrationWarnings.removeAll()
        rebuildTransform()
    }

    func reset() {
        state = .placing
        resetComponents()
        driftHistory.removeAll()
        registrationWarnings.removeAll()
        rebuildTransform()
    }

    private func resetComponents() {
        placementPosition = .zero
        placementRotation = matrix_identity_float3x3
        placementScale = 1
        appliedScale = 1
    }

    /// Drops the model's origin at a raycast hit, typically a tap on the floor.
    func place(at position: SIMD3<Float>) {
        placementPosition = position
        state = .placing
        rebuildTransform()
    }

    /// Rotate about the gravity axis. Wired to a two-finger rotation gesture.
    func rotate(byRadians delta: Float) {
        let yaw = simd_float3x3(simd_quatf(angle: delta, axis: SIMD3<Float>(0, 1, 0)))
        placementRotation = simd_float3x3(
            yaw * placementRotation.columns.0,
            yaw * placementRotation.columns.1,
            yaw * placementRotation.columns.2
        )
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

    /// Roll and pitch are deliberately not adjustable by gesture. ARKit's world
    /// origin is gravity-aligned and so is the BIM model, so the only genuinely
    /// unknown rotation at placement time is heading. Letting an operator tilt
    /// the model by hand mostly introduces error that ICP then has to undo.
    private func rebuildTransform() {
        modelToWorld = float4x4(rotation: placementRotation,
                                scale: placementScale,
                                translation: placementPosition)
        appliedScale = placementScale
    }

    /// Adopts a finished world->model transform, keeping the component
    /// representation in step so a later manual nudge starts from here rather
    /// than snapping back to the hand placement.
    private func adopt(worldToModel: float4x4) {
        let modelToWorld = worldToModel.inverse
        self.modelToWorld = modelToWorld
        let decomposed = modelToWorld.decomposedSimilarity
        placementRotation = decomposed.rotation
        placementScale = decomposed.scale
        placementPosition = decomposed.translation
        appliedScale = decomposed.scale
    }

    // MARK: - Control points

    func addControlPoint(_ pair: ControlPointPair) {
        controlPoints.append(pair)
        state = .placing
    }

    func removeControlPoint(id: UUID) {
        controlPoints.removeAll { $0.id == id }
        state = .placing
    }

    func removeAllControlPoints() {
        controlPoints.removeAll()
        registrationWarnings.removeAll()
        state = .placing
    }

    /// Registers from the dropped targets. Synchronous: the fit is closed-form
    /// over a handful of points, so there is nothing to background and an
    /// immediate answer is what makes the workflow feel like surveying rather
    /// than waiting.
    ///
    /// - Parameter allowScale: unlock uniform scale. Off by default; see
    ///   `ControlPointRegistration` for why a free scale parameter is dangerous.
    func alignToControlPoints(allowScale: Bool = false, suppliedScale: Float? = nil) {
        var options = ControlPointRegistration.Options.default
        options.allowScale = allowScale
        options.suppliedScale = suppliedScale
        options.priorRotation = placementRotation

        do {
            let fit = try ControlPointRegistration.fit(pairs: controlPoints, options: options)
            adopt(worldToModel: fit.worldToModel)
            registrationWarnings = fit.warnings
            driftHistory.removeAll()
            state = .aligned(AlignmentQuality(
                rmsError: fit.rmsError,
                // Targets have no notion of an inlier ratio; every pair is used
                // by construction. Reporting 1.0 would imply a scan-wide
                // agreement that was never measured, so this stays at zero and
                // the UI reads the method to decide what to show.
                inlierRatio: 0,
                method: .controlPoints,
                scale: fit.scale,
                establishedAt: Date(),
                degreesOfFreedom: fit.degreesOfFreedom
            ))
        } catch {
            registrationWarnings = []
            state = .failed(reason: error.localizedDescription)
        }
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

        let hadTargets = !controlPoints.isEmpty
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
                self?.applyRefinement(fine, hadTargets: hadTargets)
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

    private func applyRefinement(_ result: ICPResult, hadTargets: Bool) {
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

        adopt(worldToModel: result.worldToModel)
        driftHistory.removeAll()
        state = .aligned(AlignmentQuality(
            rmsError: result.rmsError,
            inlierRatio: result.inlierRatio,
            method: hadTargets ? .controlPointsThenICP : .icp,
            scale: appliedScale,
            establishedAt: Date(),
            degreesOfFreedom: nil
        ))
    }

    // MARK: - Dynamic registration

    /// Bounds on what may be corrected without telling anyone.
    private struct DriftPolicy {
        /// Corrections smaller than this are ordinary tracking noise and are
        /// applied silently. Roughly the accuracy of the sensor itself: below it
        /// there is nothing to distinguish drift from measurement.
        static let silentCorrection: Float = 0.015
        /// Beyond this, the world frame has moved enough that the operator needs
        /// to know and decide, rather than have the model quietly teleport under
        /// the overlay they were reading.
        static let requiresOperator: Float = 0.060
        /// Distance at which a rotational correction is evaluated. A tenth of a
        /// degree is nothing at the origin and 9 mm at ten metres, which is where
        /// the far wall of a bay actually is.
        static let workingRadius: Float = 10
        /// Minimum gap between checks.
        static let interval: TimeInterval = 6
        static let historyLimit = 40
    }

    var lastDriftCheck: Date?

    var shouldCheckForDrift: Bool {
        guard state.allowsDeviationAnalysis, !isCheckingDrift else { return false }
        guard let last = lastDriftCheck else { return true }
        return Date().timeIntervalSince(last) >= DriftPolicy.interval
    }

    /// Re-measures the registration against the current scan and corrects it.
    ///
    /// This is the piece that makes a registration hold over a long walkthrough.
    /// ARKit's world origin is not fixed: it is re-estimated continuously, and
    /// over twenty minutes and a few hundred metres of walking it moves. A
    /// transform fitted at the door is measurably wrong at the far wall, and
    /// every millimetre of that shows up as a deviation nobody built.
    ///
    /// Small corrections are applied silently. Large ones are refused and
    /// surfaced, because a jump of that size is more likely to be ICP finding a
    /// different bay than the world frame genuinely moving — and silently
    /// re-registering onto the wrong bay mid-inspection is the worst outcome
    /// available.
    ///
    /// - Parameter points: recent scan cloud in LiDAR world space.
    func checkForDrift(using points: [SIMD3<Float>], mesh: BVH) {
        guard shouldCheckForDrift, let quality = state.quality else { return }
        guard points.count >= 200, !mesh.isEmpty else { return }

        isCheckingDrift = true
        lastDriftCheck = Date()

        let current = worldToModel
        icpQueue.async { [weak self] in
            let result = PointToPlaneICP.align(
                points: points, to: mesh, initial: current, parameters: .fine)
            Task { @MainActor [weak self] in
                self?.applyDriftCheck(result, previous: current, quality: quality)
            }
        }
    }

    private func applyDriftCheck(
        _ result: ICPResult, previous: float4x4, quality: AlignmentQuality
    ) {
        defer { isCheckingDrift = false }

        guard result.rmsError.isFinite,
              result.inlierRatio >= AcceptanceCriteria.minimumInlierRatio
        else {
            // Not enough overlap to judge. Silence is correct: the operator may
            // simply be facing a blank wall, and crying drift at that would train
            // them to ignore the warning that matters.
            return
        }

        let displacement = previous.maximumDisplacement(
            from: result.worldToModel, atRadius: DriftPolicy.workingRadius)

        var sample = DriftSample(timestamp: Date(), displacementMeters: displacement,
                                 rmsError: result.rmsError, corrected: false)

        if displacement <= DriftPolicy.silentCorrection {
            // Ordinary tracking noise, and the fit is at least as good as what it
            // replaces. Take it and say nothing.
            if result.rmsError <= quality.rmsError * 1.5 {
                adopt(worldToModel: result.worldToModel)
                sample.corrected = true
            }
            state = .aligned(quality)
        } else if displacement <= DriftPolicy.requiresOperator {
            // Real drift, still plausibly the same surfaces. Correct it, but say
            // so — a finding recorded either side of a 40 mm correction is not
            // comparable with one recorded before it.
            adopt(worldToModel: result.worldToModel)
            sample.corrected = true
            state = .drifting(quality, driftMeters: displacement)
        } else {
            // Too large to be drift. Refuse it and hand the decision over.
            state = .drifting(quality, driftMeters: displacement)
        }

        driftHistory.append(sample)
        if driftHistory.count > DriftPolicy.historyLimit {
            driftHistory.removeFirst(driftHistory.count - DriftPolicy.historyLimit)
        }
    }

    /// Accepts a drift warning and returns to the aligned state without moving
    /// anything — for when the operator has looked and is satisfied.
    func acknowledgeDrift() {
        if case .drifting(let quality, _) = state {
            state = .aligned(quality)
        }
    }
}
