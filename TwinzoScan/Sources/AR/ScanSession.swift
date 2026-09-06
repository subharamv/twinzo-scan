import Foundation
import ARKit
import RealityKit
import Combine
import simd

/// Why the app cannot run, when it cannot.
enum ScanSessionError: LocalizedError {
    case lidarUnavailable
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .lidarUnavailable:
            return "This device has no LiDAR scanner. An iPhone 12 Pro or later, "
                 + "or an iPad Pro from 2020 on, is required."
        case .metalUnavailable:
            return "Could not initialise the Metal compute pipeline."
        }
    }
}

/// The application's centre of gravity: owns the ARKit session, the loaded BIM
/// model, the alignment, and the per-frame deviation pass.
@MainActor
final class ScanSession: NSObject, ObservableObject {

    // MARK: Published state

    @Published private(set) var model: BIMModel?
    @Published private(set) var statistics = DeviationStatistics()
    @Published private(set) var meshAnchorCount = 0
    @Published private(set) var scanPointCount = 0
    @Published private(set) var errorMessage: String?

    /// Hiding passing surface is the default: an inspector wants defects to
    /// stand out, not a wall of green.
    @Published var showInToleranceSurface = false {
        didSet { invalidateAllOverlays() }
    }
    /// Draw the BIM model as a faint ghost rather than a solid shell. On by
    /// default: a solid model hides the very surfaces being inspected.
    @Published var ghostModel = true {
        didSet { applyModelAppearance() }
    }
    /// Depth returns scored below this are refused entry to the scan cloud.
    ///
    /// Medium by default. A low-confidence return is ARKit telling you it does
    /// not trust the range it just measured — dark, glossy, or far surfaces,
    /// which industrial interiors are full of. Letting those into the cloud
    /// manufactures deviations indistinguishable from real ones, and this app
    /// exists to report deviations, so the default errs toward measuring less.
    @Published var minimumDepthConfidence: DepthConfidenceSampler.Level = 1

    @Published var tolerances = ToleranceSettings() {
        didSet {
            // Re-assigning here re-enters didSet exactly once: the second pass
            // is already normalised, so it falls through to the work below.
            let corrected = tolerances.normalized()
            if corrected != tolerances {
                tolerances = corrected
                return
            }
            deviation?.tolerances = tolerances
            // Every cached overlay was banded against the old thresholds.
            invalidateAllOverlays()
        }
    }

    let alignment = AlignmentCoordinator()
    let defects = DefectLog()

    // MARK: Private state

    private weak var arView: ARView?
    private var deviation: DeviationEngine?
    private let scanCloud = ScanCloud()

    /// Root for the BIM model, re-posed whenever the alignment changes.
    private var modelAnchor: AnchorEntity?
    /// Root for the deviation overlay. Kept separate from the model so the two
    /// can be shown and hidden independently.
    private var overlayAnchor: AnchorEntity?
    private var overlayEntities: [UUID: ModelEntity] = [:]

    /// Anchors whose overlay is out of date. ARKit updates far more anchors per
    /// second than we can afford to re-evaluate, so work is queued and spent
    /// against a fixed per-frame budget.
    private var dirtyAnchors: [UUID: ARMeshAnchor] = [:]
    private var perFrameStats: [UUID: DeviationStatistics] = [:]
    /// Every mesh anchor ARKit has told us about and not retracted.
    private var knownAnchors: Set<UUID> = []

    /// Mesh chunks re-evaluated per frame. Three keeps the deviation pass inside
    /// roughly two milliseconds on an A15, leaving the frame budget to rendering.
    private let anchorBudgetPerFrame = 3

    /// Camera pose at the last accumulation, for the motion gate below.
    private var lastAccumulationTransform: float4x4?

    /// Half the voxel pitch. Moving less than this cannot expose a voxel the grid
    /// does not already hold, so re-folding the same vertices in is pure cost —
    /// and an operator standing still reading the readout is the common case.
    private static let accumulationTranslationSquared: Float = (0.05 / 2) * (0.05 / 2)
    /// One degree of heading. At five metres that sweeps about nine centimetres,
    /// which is a voxel and a half of fresh surface.
    private static let accumulationRotationCosine: Float = cos(Float.pi / 180)

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    override init() {
        super.init()
        // `alignment` is a nested ObservableObject, so its changes do not reach
        // views observing this one. Forward them, or the status banner silently
        // stops updating when ICP finishes.
        alignment.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        defects.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func dismissError() {
        errorMessage = nil
    }

    func start(in view: ARView) throws {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            throw ScanSessionError.lidarUnavailable
        }
        guard let engine = DeviationEngine() else {
            throw ScanSessionError.metalUnavailable
        }

        arView = view
        deviation = engine
        engine.tolerances = tolerances

        view.session.delegate = self
        view.automaticallyConfigureSession = false
        view.environment.sceneUnderstanding.options = []
        view.renderOptions.insert(.disableMotionBlur)
        view.session.run(Self.makeConfiguration(),
                         options: [.resetTracking, .removeExistingAnchors])

        let modelAnchor = AnchorEntity(world: .zero)
        let overlayAnchor = AnchorEntity(world: .zero)
        view.scene.addAnchor(modelAnchor)
        view.scene.addAnchor(overlayAnchor)
        self.modelAnchor = modelAnchor
        self.overlayAnchor = overlayAnchor

        // Re-pose the model whenever the alignment changes, whether that came
        // from a gesture or from ICP finishing.
        alignment.$modelToWorld
            .sink { [weak self] transform in
                self?.modelAnchor?.transform = Transform(matrix: transform)
                self?.invalidateAllOverlays()
            }
            .store(in: &cancellables)
    }

    func pause() {
        arView?.session.pause()
    }

    private static func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        // Classification is not used for banding, but it is what lets a later
        // pass exclude floors or filter by element type without a second scan.
        configuration.sceneReconstruction = .meshWithClassification
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        // Smoothed depth is temporally filtered, so a vertex sitting on a
        // confidence boundary does not flicker between accepted and rejected
        // across successive frames. Only the confidence map is read from it.
        if type(of: configuration).supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        return configuration
    }

    // MARK: - Model loading

    func loadModel(from url: URL) {
        // Security-scoped access: models usually arrive through the document
        // picker from Files or a cloud drive rather than the app bundle.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let loaded = try BIMModelLoader.load(from: url)
            model = loaded
            deviation?.load(mesh: loaded.bvh)

            modelAnchor?.children.removeAll()
            modelAnchor?.addChild(loaded.entity)
            applyModelAppearance()

            clearOverlays()
            alignment.modelDidLoad()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyModelAppearance() {
        guard let entity = model?.entity else { return }
        let material = SimpleMaterial(
            color: ghostModel
                ? .init(white: 1.0, alpha: 0.18)
                : .init(white: 1.0, alpha: 0.65),
            isMetallic: false
        )
        entity.applyRecursively { $0.model?.materials = [material] }
    }

    // MARK: - Placement and alignment

    /// Places the model where the operator tapped, raycast against detected
    /// geometry. Called from the tap gesture in `ARViewContainer`.
    func placeModel(atScreenPoint point: CGPoint) {
        guard let arView, model != nil else { return }
        let results = arView.raycast(from: point,
                                     allowing: .estimatedPlane,
                                     alignment: .any)
        guard let hit = results.first else {
            errorMessage = "No surface found there. Aim at the floor and try again."
            return
        }
        alignment.place(at: hit.worldTransform.translation)
        errorMessage = nil
    }

    /// Slides the model across the ground plane in axes relative to where the
    /// operator is standing, so a drag "away" pushes it away from them whichever
    /// direction they happen to be facing.
    func nudgeModelInCameraPlane(right: Float, forward: Float) {
        guard let camera = arView?.session.currentFrame?.camera else { return }
        let orientation = camera.transform

        // Project the camera basis onto the ground plane. The camera looks down
        // its own -Z, and near-vertical device poses make that projection
        // degenerate, so fall back to the up vector when looking at the floor.
        var forwardAxis = -orientation.columns.2.xyz
        forwardAxis.y = 0
        if length(forwardAxis) < 0.1 {
            forwardAxis = orientation.columns.1.xyz
            forwardAxis.y = 0
        }
        guard length(forwardAxis) > 1e-4 else { return }
        forwardAxis = normalize(forwardAxis)
        let rightAxis = SIMD3<Float>(-forwardAxis.z, 0, forwardAxis.x)

        let delta = rightAxis * right + forwardAxis * forward
        alignment.nudge(x: delta.x, z: delta.z)
    }

    /// Reports a failure raised while bringing the session up, so it reaches the
    /// UI instead of leaving a blank camera feed.
    func reportStartupFailure(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Kicks off ICP against everything scanned so far.
    func refineAlignment() {
        guard let model else { return }
        alignment.refine(using: scanCloud.points(), mesh: model.bvh)
    }

    func resetAlignment() {
        alignment.reset()
        clearOverlays()
    }

    func resetScan() {
        scanCloud.removeAll()
        scanPointCount = 0
        lastAccumulationTransform = nil
        clearOverlays()
        arView?.session.run(Self.makeConfiguration(), options: [.resetSceneReconstruction])
    }

    // MARK: - Export

    /// Writes the accumulated cloud out as a binary PLY, in model coordinates.
    ///
    /// The defect CSV records where the app believes the problems are; this
    /// records what it actually measured. An engineer disputing a finding will
    /// ask for the second, and the confidence byte travels with it so the
    /// measurement can be re-filtered downstream on the same evidence.
    /// Sortable, and free of the colons ISO 8601 would put in a filename.
    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    func exportScanCloud() throws -> URL {
        let cloud = scanCloud.pointsWithConfidence()
        let name = model?.name ?? "scan"
        let stamp = Self.fileStampFormatter.string(from: Date())

        let data = PointCloudPLY.data(
            points: cloud.points,
            confidences: cloud.confidences,
            worldToModel: alignment.worldToModel,
            comment: "Twinzo Scan \(name) \(stamp)"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(stamp).ply")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Overlay bookkeeping

    private func clearOverlays() {
        overlayAnchor?.children.removeAll()
        overlayEntities.removeAll()
        dirtyAnchors.removeAll()
        perFrameStats.removeAll()
        defects.removeAll()
        statistics = DeviationStatistics()
    }

    /// Marks every known anchor for re-evaluation. Needed after anything that
    /// changes the meaning of the existing colours: a new alignment, new
    /// tolerances, or a display toggle.
    private func invalidateAllOverlays() {
        guard let frame = arView?.session.currentFrame else { return }
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            dirtyAnchors[anchor.identifier] = anchor
        }
    }

    /// Spends the per-frame budget on queued anchors.
    ///
    /// Both the CPU vertex copy that feeds ICP and the GPU deviation dispatch run
    /// from here rather than straight off the delegate callback. ARKit re-emits
    /// mesh chunks far faster than either can be absorbed, and doing this work
    /// inline was the difference between a steady 60 fps and a stuttering one.
    /// Whether the camera has moved enough since the last accumulation for there
    /// to be new surface worth folding into the cloud.
    ///
    /// Gates accumulation only, never the deviation pass: re-banding after a
    /// tolerance change has to run whether or not the operator is moving, and
    /// that is exactly when they are standing still reading the numbers.
    private func shouldAccumulate(camera: ARCamera) -> Bool {
        guard let last = lastAccumulationTransform else { return true }
        let current = camera.transform
        let turned = simd_dot(current.columns.2, last.columns.2) <= Self.accumulationRotationCosine
        let moved = simd_distance_squared(current.columns.3, last.columns.3)
            >= Self.accumulationTranslationSquared
        return turned || moved
    }

    private func processDirtyAnchors() {
        guard !dirtyAnchors.isEmpty else { return }

        let frame = arView?.session.currentFrame
        let accumulating = frame.map { shouldAccumulate(camera: $0.camera) } ?? false
        // Built per frame and released at the end of this pass: the confidence
        // buffer belongs to the ARFrame, and holding it starves ARKit's pool.
        let sampler = accumulating ? frame.flatMap(DepthConfidenceSampler.init(frame:)) : nil
        let score: ((SIMD3<Float>) -> DepthConfidenceSampler.Level?)? = sampler.map { sampler in
            { sampler.level(atWorld: $0) }
        }

        let canAnalyse = alignment.state.allowsDeviationAnalysis && deviation?.hasModel == true
        let worldToModel = alignment.worldToModel
        var processed = 0

        for (id, anchor) in dirtyAnchors {
            if processed >= anchorBudgetPerFrame { break }
            dirtyAnchors.removeValue(forKey: id)
            processed += 1

            // One CPU copy of the chunk's vertices per pass, shared by the ICP
            // cloud and the defect log.
            let positions = anchor.geometry.vertexPositions()

            // The ICP cloud accumulates whatever the alignment state: the
            // operator needs something to align against before alignment exists.
            if accumulating {
                scanCloud.insert(points: positions,
                                 transform: anchor.transform,
                                 minimumConfidence: minimumDepthConfidence,
                                 confidence: score)
            }

            guard canAnalyse,
                  let field = deviation?.evaluate(anchor: anchor, worldToModel: worldToModel)
            else { continue }

            perFrameStats[id] = field.statistics
            defects.record(field: field, anchor: anchor,
                           positions: positions, tolerance: tolerances.tolerance)
            updateOverlayEntity(for: anchor, field: field, positions: positions)
        }

        guard processed > 0 else { return }
        // Only mark the pose spent once work actually happened against it, or a
        // frame that hit an empty budget would suppress the next one.
        if accumulating, let frame {
            lastAccumulationTransform = frame.camera.transform
        }
        scanPointCount = scanCloud.count
        if canAnalyse {
            statistics = perFrameStats.values.reduce(DeviationStatistics(), +)
        }
    }

    private func updateOverlayEntity(
        for anchor: ARMeshAnchor, field: DeviationField, positions: [SIMD3<Float>]
    ) {
        // Replace rather than mutate: RealityKit has no cheap path for swapping
        // a mesh's face-to-material mapping in place, and these chunks are small.
        if let existing = overlayEntities.removeValue(forKey: anchor.identifier) {
            existing.removeFromParent()
        }
        guard let entity = DeviationOverlay.makeEntity(
            for: anchor, field: field, positions: positions,
            showInTolerance: showInToleranceSurface
        ) else { return }

        entity.transform = Transform(matrix: anchor.transform)
        overlayAnchor?.addChild(entity)
        overlayEntities[anchor.identifier] = entity
    }
}

// MARK: - ARSessionDelegate

extension ScanSession: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor in self.ingest(meshes) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshes.isEmpty else { return }
        Task { @MainActor in self.ingest(meshes) }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.map(\.identifier)
        Task { @MainActor in self.forget(ids) }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in self.processDirtyAnchors() }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.errorMessage = error.localizedDescription }
    }

    /// Queues anchors for the budgeted worker. Deliberately does no geometry
    /// work: this runs on every ARKit mesh update, which is a hot path.
    @MainActor
    private func ingest(_ meshes: [ARMeshAnchor]) {
        for anchor in meshes {
            dirtyAnchors[anchor.identifier] = anchor
            knownAnchors.insert(anchor.identifier)
        }
        meshAnchorCount = knownAnchors.count
    }

    @MainActor
    private func forget(_ ids: [UUID]) {
        for id in ids {
            knownAnchors.remove(id)
            dirtyAnchors.removeValue(forKey: id)
            perFrameStats.removeValue(forKey: id)
            overlayEntities.removeValue(forKey: id)?.removeFromParent()
            defects.forget(anchorID: id)
        }
        meshAnchorCount = knownAnchors.count
    }
}

extension Entity {
    /// Applies a change to this entity and every descendant that has a model.
    func applyRecursively(_ body: (ModelEntity) -> Void) {
        if let model = self as? ModelEntity { body(model) }
        for child in children { child.applyRecursively(body) }
    }
}
