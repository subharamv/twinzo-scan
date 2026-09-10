import Foundation
import Metal
import ARKit
import simd

/// Per-vertex deviation results for one ARKit mesh anchor.
struct DeviationField {
    /// Index into `DeviationPalette.bands` for each vertex.
    var bands: [UInt32]
    /// Signed distance to the nearest BIM surface, in metres. NaN where no
    /// surface fell within the rejection radius.
    var signedDistances: [Float]
    /// Owning BIM element per vertex, or `GPUTriangle.unattributedElement`.
    /// This is what turns a heat map into "column C-12 is 19 mm out".
    var elementIndices: [UInt32]
    /// Model-space vector from the design surface to the scanned point; `w`
    /// repeats the signed distance so one buffer read serves both consumers.
    var deltas: [SIMD4<Float>]
    var statistics: DeviationStatistics
}

/// GPU-side signed-distance evaluation of a LiDAR mesh against the BIM model.
///
/// The BVH is uploaded once per loaded model. Each frame only the (comparatively
/// tiny) vertex buffer of a changed mesh anchor crosses the bus, so the per-frame
/// cost is a single dispatch of one thread per vertex.
final class DeviationEngine {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    // Model-resident buffers, rebuilt only when a new BIM model is loaded.
    private var nodeBuffer: MTLBuffer?
    private var triangleBuffer: MTLBuffer?
    private var normalBuffer: MTLBuffer?

    // Scratch buffers, grown on demand and reused across frames to keep the
    // per-frame allocation count at zero once the scan reaches steady state.
    private var bandBuffer: MTLBuffer?
    private var distanceBuffer: MTLBuffer?
    private var elementBuffer: MTLBuffer?
    private var deltaBuffer: MTLBuffer?
    private var statsBuffer: MTLBuffer

    var tolerances = ToleranceSettings()

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        // Failable all the way down: the Simulator has no Metal device at all,
        // and force-unwrapping here would crash before the UI could explain why.
        guard let device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "computeDeviation"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let stats = device.makeBuffer(length: MemoryLayout<UInt32>.stride * 5,
                                            options: .storageModeShared)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.statsBuffer = stats
    }

    // MARK: - Model residency

    /// Uploads a freshly built BVH. Cheap enough to call on model load, far too
    /// expensive for the frame loop.
    func load(mesh: BVH) {
        guard !mesh.isEmpty else {
            nodeBuffer = nil
            triangleBuffer = nil
            normalBuffer = nil
            return
        }
        nodeBuffer = mesh.nodes.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        triangleBuffer = mesh.triangles.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        // Normals are padded to float4 so the shader can index them with the
        // same stride rules as everything else.
        let padded = mesh.normals.map { SIMD4<Float>($0, 0) }
        normalBuffer = padded.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }

    var hasModel: Bool { nodeBuffer != nil }

    // MARK: - Per-frame evaluation

    /// Evaluates one ARKit mesh anchor against the loaded model.
    ///
    /// - Parameters:
    ///   - anchor: the mesh chunk ARKit just added or updated.
    ///   - worldToModel: current alignment, LiDAR world space -> BIM model space.
    /// - Returns: nil when no model is loaded or the dispatch could not be built.
    func evaluate(anchor: ARMeshAnchor, worldToModel: float4x4) -> DeviationField? {
        guard let nodeBuffer, let triangleBuffer, let normalBuffer else { return nil }

        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        guard vertexCount > 0 else { return nil }

        // The kernel reads this buffer as `packed_float3`. ARKit has always
        // supplied tightly packed 12-byte vertices, but nothing in the API
        // guarantees it — and a stride change would not fail, it would silently
        // shear the geometry and report fictitious deviations. Check rather than
        // trust.
        guard geometry.vertices.format == .float3,
              geometry.vertices.stride == MemoryLayout<Float>.size * 3
        else {
            assertionFailure(
                "Unexpected ARKit vertex layout: format \(geometry.vertices.format.rawValue), "
              + "stride \(geometry.vertices.stride). The deviation kernel expects packed float3.")
            return nil
        }

        // ARKit vertices live in anchor space; fold the anchor pose into the
        // matrix rather than transforming the cloud on the CPU first.
        let combined = worldToModel * anchor.transform

        ensureScratchCapacity(vertexCount: vertexCount)
        guard let bandBuffer, let distanceBuffer, let elementBuffer, let deltaBuffer,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        memset(statsBuffer.contents(), 0, statsBuffer.length)

        var uniforms = DeviationUniforms(
            worldToModel: combined,
            toleranceMeters: tolerances.tolerance,
            saturationMeters: tolerances.saturation,
            rejectMeters: tolerances.rejection,
            vertexCount: UInt32(vertexCount)
        )

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(geometry.vertices.buffer, offset: geometry.vertices.offset, index: 0)
        encoder.setBuffer(bandBuffer, offset: 0, index: 1)
        encoder.setBuffer(distanceBuffer, offset: 0, index: 2)
        encoder.setBuffer(nodeBuffer, offset: 0, index: 3)
        encoder.setBuffer(triangleBuffer, offset: 0, index: 4)
        encoder.setBuffer(normalBuffer, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<DeviationUniforms>.stride, index: 6)
        encoder.setBuffer(statsBuffer, offset: 0, index: 7)
        encoder.setBuffer(elementBuffer, offset: 0, index: 8)
        encoder.setBuffer(deltaBuffer, offset: 0, index: 9)

        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: vertexCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        // Synchronous: the caller needs the bands to rebuild this anchor's
        // overlay mesh immediately, and one anchor is a sub-millisecond dispatch.
        commandBuffer.waitUntilCompleted()

        let bands = Array(UnsafeBufferPointer(
            start: bandBuffer.contents().assumingMemoryBound(to: UInt32.self),
            count: vertexCount
        ))
        let distances = Array(UnsafeBufferPointer(
            start: distanceBuffer.contents().assumingMemoryBound(to: Float.self),
            count: vertexCount
        ))
        let elements = Array(UnsafeBufferPointer(
            start: elementBuffer.contents().assumingMemoryBound(to: UInt32.self),
            count: vertexCount
        ))
        let deltas = Array(UnsafeBufferPointer(
            start: deltaBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self),
            count: vertexCount
        ))

        return DeviationField(bands: bands,
                              signedDistances: distances,
                              elementIndices: elements,
                              deltas: deltas,
                              statistics: readStatistics())
    }

    private func ensureScratchCapacity(vertexCount: Int) {
        let bandLength = MemoryLayout<UInt32>.stride * vertexCount
        guard (bandBuffer?.length ?? 0) < bandLength else { return }

        // Over-allocate so a slowly growing anchor does not reallocate every
        // time ARKit refines it. All four scratch buffers are grown together
        // and gated on the same check: sizing them independently is how one
        // ends up a frame behind the others and the kernel writes past its end.
        let headroom = 1.5
        func scratch(_ stride: Int) -> MTLBuffer? {
            device.makeBuffer(length: Int(Double(stride * vertexCount) * headroom),
                              options: .storageModeShared)
        }
        bandBuffer = scratch(MemoryLayout<UInt32>.stride)
        distanceBuffer = scratch(MemoryLayout<Float>.stride)
        elementBuffer = scratch(MemoryLayout<UInt32>.stride)
        deltaBuffer = scratch(MemoryLayout<SIMD4<Float>>.stride)
    }

    private func readStatistics() -> DeviationStatistics {
        let raw = statsBuffer.contents().assumingMemoryBound(to: UInt32.self)
        var stats = DeviationStatistics()
        stats.inToleranceCount = Int(raw[0])
        stats.outOfToleranceCount = Int(raw[1])
        stats.unmatchedCount = Int(raw[2])
        let compared = Float(max(stats.comparedCount, 1))
        // Shader accumulates tenths of a millimetre; convert back to metres.
        stats.meanDeviation = Float(raw[3]) / compared * 1e-4
        stats.maxDeviation = Float(raw[4]) * 1e-4
        return stats
    }
}
