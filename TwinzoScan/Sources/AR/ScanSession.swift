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
    /// Per-element findings, refreshed on a throttle. This is the M12 output:
    /// the form a deviation has to be in before anyone can act on it.
    @Published private(set) var elementInspections: [ElementInspection] = []
    @Published private(set) var inspectionSummary = InspectionSummary()
    /// How much of the design model the scan has reached. Nil until a coverage
    /// pass has been asked for.
    @Published private(set) var coverage: CoverageReport?
    @Published private(set) var isComputingCoverage = false
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
    /// Let real geometry hide the BIM overlay behind it.
    ///
    /// Off by default, and it is a genuine trade rather than an oversight. With
    /// occlusion on, the model sits believably inside the room and the AR reads
    /// correctly; with it off, an operator can see the design surface *through*
    /// the built one, which is exactly what they need when the question is "how
    /// far apart are these two". Module 2 wants it on, module 5 wants it off.
    @Published var occludeModelWithScene = false {
        didSet { applySceneUnderstanding() }
    }
    /// Judge each element against the limit for its own class rather than one
    /// project-wide number. On by default: a single tolerance across structure,
    /// MEP and finishes is wrong for at least two of the three.
    @Published var useClassTolerances = true {
        didSet { invalidateAllOverlays(); publishInspections(force: true) }
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

    /// What a tap on the camera view does.
    ///
    /// Modal rather than a set of separate gestures because all three want the
    /// same one — a single unambiguous tap on a surface — and stacking them onto
    /// tap counts or long presses on a device held at arm's length in a hard hat
    /// is how an operator drops a target where they meant to identify a column.
    enum InteractionMode: String, CaseIterable, Identifiable {
        /// Drop the model where you tap, and slide and twist it into place.
        case place
        /// Tap a real surface, then the matching point on the model, to build a
        /// surveyed target pair.
        case target
        /// Tap a surface to pull up the element it belongs to.
        case identify

        var id: String { rawValue }

        var title: String {
            switch self {
            case .place:    return "Place"
            case .target:   return "Targets"
            case .identify: return "Identify"
            }
        }

        var systemImage: String {
            switch self {
            case .place:    return "hand.tap"
            case .target:   return "scope"
            case .identify: return "info.circle"
            }
        }
    }

    @Published var interactionMode: InteractionMode = .place {
        didSet { pendingTargetWorldPoint = nil }
    }

    /// First half of a target pair: the real-world point, waiting for its
    /// counterpart to be picked on the model.
    @Published private(set) var pendingTargetWorldPoint: SIMD3<Float>?
    /// Element the operator last tapped, shown in the identify card.
    @Published private(set) var selectedElementIndex: UInt32?

    var selectedInspection: ElementInspection? {
        guard let selectedElementIndex else { return nil }
        return elementInspections.first { $0.element.index == selectedElementIndex }
    }

    func selectElement(_ index: UInt32?) {
        selectedElementIndex = index
    }

    // MARK: Private state

    private weak var arView: ARView?
    private var deviation: DeviationEngine?
    /// Grid pitch of the accumulated scan cloud, metres.
    ///
    /// One constant, not one per consumer. It sets the cloud, derives the
    /// coverage search radius, and is uploaded as part of the session record —
    /// and a second copy of it somewhere else would mean the number stored
    /// alongside an inspection could stop describing the scan that produced it.
    static let scanVoxelSize: Float = 0.05
    private let scanCloud = ScanCloud(voxelSize: ScanSession.scanVoxelSize)
    /// Per-element aggregation. Value type, mutated only on the main actor.
    private var inspections = ElementInspectionEngine()
    private var lastInspectionPublish = Date.distantPast
    /// Rebuilding the published array walks every element in the model, which is
    /// tens of thousands of rows on a real building. Twice a second is faster
    /// than anyone reads and cheap enough to disappear into the frame budget.
    private static let inspectionPublishInterval: TimeInterval = 0.5
    private let coverageQueue = DispatchQueue(label: "com.twinzo.scan.coverage",
                                              qos: .utility)

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
        view.renderOptions.insert(.disableMotionBlur)
        applySceneUnderstanding()
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
            if loaded.addressableFraction < 0.5 {
                // Not an error — the app works fine without metadata — but the
                // operator has to know before scanning rather than after that
                // findings from this model cannot be written back to Revit.
                errorMessage = String(
                    format: "Only %.0f%% of the elements in this model carry an IFC id. Findings "
                          + "will be reportable but will not round-trip to the authoring model. "
                          + "Re-export with the elements.json sidecar to fix that.",
                    loaded.addressableFraction * 100)
            }
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

    /// Dispatches a tap according to the current mode.
    func handleTap(atScreenPoint point: CGPoint) {
        switch interactionMode {
        case .place:
            guard !alignment.state.allowsDeviationAnalysis else { return }
            placeModel(atScreenPoint: point)
        case .target:
            pickTarget(atScreenPoint: point)
        case .identify:
            identifyElement(atScreenPoint: point)
        }
    }

    /// Casts the tap into the BIM model and returns what it hit.
    ///
    /// The ray is built in world space and then moved into model space, rather
    /// than the model being moved: the BVH is millions of triangles and the ray
    /// is two vectors. Direction is transformed as a direction, so a model placed
    /// at a scale still gets a ray pointing the right way.
    private func modelHit(atScreenPoint point: CGPoint) -> RayHit? {
        guard let arView, let model, let ray = arView.ray(through: point) else { return nil }
        let worldToModel = alignment.worldToModel
        return model.bvh.raycast(
            origin: worldToModel.transformPoint(ray.origin),
            direction: worldToModel.transformDirection(ray.direction),
            maxDistance: 60
        )
    }

    /// Tap a surface, get the element. The whole of M12 in one gesture.
    private func identifyElement(atScreenPoint point: CGPoint) {
        guard model != nil else {
            errorMessage = "Load a model before identifying elements."
            return
        }
        guard let hit = modelHit(atScreenPoint: point) else {
            selectedElementIndex = nil
            errorMessage = "No model surface there. Aim at part of the overlaid model."
            return
        }
        guard hit.elementIndex != GPUTriangle.unattributedElement else {
            selectedElementIndex = nil
            errorMessage = "That surface carries no element metadata, so it cannot be identified. "
                         + "Re-export the model with its elements.json sidecar."
            return
        }
        selectedElementIndex = hit.elementIndex
        errorMessage = nil
    }

    /// Builds a target pair in two taps: the real point, then its counterpart on
    /// the model.
    ///
    /// Two taps rather than one because the two points are genuinely different
    /// measurements. The first is where the thing *is*; the second is where the
    /// design says it should be. Collapsing them into one gesture would mean
    /// guessing the correspondence, which is the one thing a surveyed alignment
    /// exists to avoid.
    private func pickTarget(atScreenPoint point: CGPoint) {
        guard let arView, model != nil else {
            errorMessage = "Load a model before placing targets."
            return
        }

        guard let world = pendingTargetWorldPoint else {
            let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
            guard let hit = results.first else {
                errorMessage = "No surface found there. Aim at the feature itself and try again."
                return
            }
            pendingTargetWorldPoint = hit.worldTransform.translation
            errorMessage = nil
            return
        }

        guard let hit = modelHit(atScreenPoint: point) else {
            errorMessage = "No model surface there. Tap the matching point on the overlaid model, "
                         + "or start over."
            return
        }

        alignment.addControlPoint(ControlPointPair(
            worldPoint: world,
            modelPoint: hit.point,
            label: "Target \(alignment.controlPoints.count + 1)",
            elementIndex: hit.elementIndex == GPUTriangle.unattributedElement
                ? nil : hit.elementIndex
        ))
        pendingTargetWorldPoint = nil
        errorMessage = nil
    }

    func cancelPendingTarget() {
        pendingTargetWorldPoint = nil
    }

    /// Places the model where the operator tapped, raycast against detected
    /// geometry.
    private func placeModel(atScreenPoint point: CGPoint) {
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
        inspections.removeAll()
        statistics = DeviationStatistics()
        // Coverage was measured against the alignment being torn down, so it has
        // stopped being a statement about anything.
        coverage = nil
        publishInspections(force: true)
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
            inspections.ingest(
                anchorID: id,
                elementIndices: field.elementIndices,
                signedDistances: field.signedDistances,
                deltas: field.deltas,
                positions: positions,
                // Anchor space. The accumulator applies this only to the samples
                // that turn out to be a chunk's worst, rather than to every
                // vertex of every chunk on every frame.
                positionTransform: anchor.transform,
                toleranceFor: tolerance(forElement:)
            )
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
            publishInspections()
            runDriftCheckIfDue()
        }
    }

    // MARK: - Per-element results

    /// Threshold one element is judged against.
    ///
    /// Falls back to the project-wide setting for anything unclassified rather
    /// than guessing: an element whose class nobody established should be
    /// measured against the number the operator chose, not one this app inferred
    /// from a substring of its name.
    private func tolerance(forElement index: UInt32) -> Float {
        guard useClassTolerances,
              let element = model?.element(at: index),
              element.toleranceClass != .unclassified
        else { return tolerances.tolerance }
        return element.toleranceClass.settings.tolerance
    }

    private func publishInspections(force: Bool = false) {
        guard let model else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastInspectionPublish)
                >= Self.inspectionPublishInterval else { return }
        lastInspectionPublish = now

        let results = inspections.inspections(
            elements: model.elements,
            coverage: coverage?.byElement ?? [:],
            toleranceFor: tolerance(forElement:)
        )
        elementInspections = results
        inspectionSummary = InspectionSummary(results)
    }

    /// Elements that failed, worst first. What the inspector actually opens.
    var failedInspections: [ElementInspection] {
        elementInspections
            .filter { $0.status == .fail }
            .sorted { $0.maxAbsolute > $1.maxAbsolute }
    }

    // MARK: - Coverage

    /// Measures how much of the design model the scan has reached.
    ///
    /// Run on demand rather than continuously: it samples the whole model, which
    /// is seconds of work on a real building, and the answer only changes as fast
    /// as somebody can walk.
    func computeCoverage() {
        guard let model, !isComputingCoverage,
              alignment.state.allowsDeviationAnalysis else { return }

        isComputingCoverage = true
        let mesh = model.bvh
        let points = scanCloud.points()
        let worldToModel = alignment.worldToModel
        let parameters = CoverageAnalyzer.Parameters.forVoxelSize(Self.scanVoxelSize)

        coverageQueue.async { [weak self] in
            let report = CoverageAnalyzer.analyze(
                mesh: mesh, scanPoints: points,
                worldToModel: worldToModel, parameters: parameters)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.coverage = report
                self.isComputingCoverage = false
                // Coverage changes verdicts: an element that read as passing on
                // a handful of samples becomes insufficientData once we know how
                // little of it was actually seen.
                self.publishInspections(force: true)
            }
        }
    }

    // MARK: - Dynamic registration

    /// Hands the drift monitor a fresh look at the scan when one is due.
    ///
    /// Driven from the frame loop rather than from a timer so it can never run
    /// while the session is paused or backgrounded, and so it stops costing
    /// anything the moment the operator stops scanning.
    private func runDriftCheckIfDue() {
        guard let model, alignment.shouldCheckForDrift else { return }
        alignment.checkForDrift(using: scanCloud.points(), mesh: model.bvh)
    }

    private func applySceneUnderstanding() {
        arView?.environment.sceneUnderstanding.options =
            occludeModelWithScene ? [.occlusion] : []
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
            inspections.forget(anchorID: id)
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
