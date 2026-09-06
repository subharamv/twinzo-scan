import ARKit
import simd

/// ARKit's per-pixel depth confidence, sampled for arbitrary world points.
///
/// `ARMeshAnchor` carries no confidence of its own: ARKit fuses many frames into
/// the mesh and discards the per-return quality that produced it. The raw
/// `sceneDepth` buffer for the frame in flight does carry it, so a mesh vertex
/// that happens to be in view can still be scored by projecting it back into
/// that buffer.
///
/// Scoring only reaches vertices currently in view, which is exactly where it is
/// wanted: `ScanCloud` keeps the first point to land in each voxel, so a vertex
/// is tested on the frame it is first seen and never re-tested afterwards. A
/// vertex outside the frustum returns nil — absence of evidence, not evidence of
/// a bad return — and is accumulated as before.
///
/// Locks the confidence buffer for its whole lifetime, so build one per frame
/// and let it go out of scope promptly. Never hold one across frames: the
/// pixel buffer belongs to the `ARFrame` and retaining it starves ARKit's pool.
final class DepthConfidenceSampler {

    /// ARKit's own scale, matching `ARConfidenceLevel`: 0 low, 1 medium, 2 high.
    typealias Level = UInt8

    private let confidenceMap: CVPixelBuffer
    private let base: UnsafeRawPointer
    private let bytesPerRow: Int
    private let width: Int
    private let height: Int

    private let worldToCamera: float4x4
    private let intrinsics: simd_float3x3
    /// Confidence-map pixels per capture-image pixel. The depth and confidence
    /// buffers are far smaller than the colour image (256x192 against 1920x1440
    /// on current hardware) but share its framing, so a plain scale is exact.
    private let pixelScale: SIMD2<Float>

    /// Fails when the frame carries no depth: a device without LiDAR, or the
    /// first frames before the sensor has produced anything.
    init?(frame: ARFrame) {
        // Prefer the smoothed buffer where the configuration asked for it: it is
        // temporally filtered, so a vertex near a confidence boundary does not
        // flicker between accepted and rejected on successive frames.
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let map = depth.confidenceMap else { return nil }

        // ARConfidenceLevel is written as one byte per pixel. Anything else means
        // Apple changed the format and the pointer arithmetic below is wrong.
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_OneComponent8 else {
            return nil
        }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let resolution = frame.camera.imageResolution
        guard width > 0, height > 0, resolution.width > 0, resolution.height > 0 else { return nil }

        // Lock last: a failed initialiser must not leave the buffer locked, and
        // every fallible step above has already been cleared.
        guard CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        guard let address = CVPixelBufferGetBaseAddress(map) else {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            return nil
        }

        self.confidenceMap = map
        self.base = UnsafeRawPointer(address)
        self.bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        self.width = width
        self.height = height
        self.worldToCamera = frame.camera.transform.inverse
        self.intrinsics = frame.camera.intrinsics
        self.pixelScale = SIMD2<Float>(Float(width) / Float(resolution.width),
                                       Float(height) / Float(resolution.height))
    }

    deinit {
        CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
    }

    /// Confidence of the depth return covering `point`, or nil when the point is
    /// behind the camera or outside the frame.
    func level(atWorld point: SIMD3<Float>) -> Level? {
        let camera = worldToCamera.transformPoint(point)

        // ARKit's camera space looks down its own -Z with +Y up; the pinhole
        // model behind `intrinsics` looks down +Z with +Y down. Flip both.
        let z = -camera.z
        guard z > 0.01 else { return nil }

        let projected = intrinsics * SIMD3<Float>(camera.x, -camera.y, z)
        guard projected.z > 0 else { return nil }

        let column = Int((projected.x / projected.z) * pixelScale.x)
        let row = Int((projected.y / projected.z) * pixelScale.y)
        guard column >= 0, column < width, row >= 0, row < height else { return nil }

        return base.load(fromByteOffset: row * bytesPerRow + column, as: UInt8.self)
    }
}
