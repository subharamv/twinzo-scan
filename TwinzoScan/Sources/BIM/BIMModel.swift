import Foundation
import RealityKit
import simd

/// A BIM model prepared for on-device comparison.
///
/// `entity` is what RealityKit draws; `bvh` is the same geometry flattened into a
/// triangle soup for distance queries. They are produced together so the overlay
/// and the numbers can never drift apart.
struct BIMModel {
    var name: String
    var entity: ModelEntity
    var bvh: BVH
    var triangleCount: Int
    /// Axis-aligned extents in model space, used to seed a sensible initial
    /// placement distance and to sanity-check units.
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    var sizeMeters: SIMD3<Float> { bounds.max - bounds.min }
}

enum BIMLoaderError: LocalizedError {
    case unreadable(URL)
    case noGeometry
    case suspiciousScale(SIMD3<Float>)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "Could not open \(url.lastPathComponent). Convert Revit/IFC exports to USDZ first."
        case .noGeometry:
            return "The model loaded but contains no triangles."
        case .suspiciousScale(let size):
            let d = size.max()
            return String(
                format: "Model spans %.1f units on its longest axis, which is unlikely in metres. "
                      + "Check the export units (Revit commonly writes millimetres or feet).", d)
        }
    }
}

/// Loads converted BIM geometry (USDZ or .reality) and prepares it for comparison.
///
/// Revit and IFC do not load natively on iOS. The expected pipeline is an offline
/// conversion — Revit -> IFC/FBX -> USDZ — with the result either bundled or
/// fetched from the twin backend. This loader deliberately validates scale on the
/// way in, because a millimetre-unit export silently produces a model 1000x too
/// large and every downstream deviation number becomes meaningless.
enum BIMModelLoader {

    /// Longest-axis extent beyond which the model is almost certainly not in metres.
    private static let implausibleExtentMeters: Float = 5_000

    static func load(from url: URL, unitScale: Float = 1.0) throws -> BIMModel {
        let entity: ModelEntity
        do {
            entity = try ModelEntity.loadModel(contentsOf: url)
        } catch {
            throw BIMLoaderError.unreadable(url)
        }
        if unitScale != 1.0 {
            entity.scale = SIMD3<Float>(repeating: unitScale)
        }

        var triangles: [GPUTriangle] = []
        collectTriangles(from: entity, parentTransform: matrix_identity_float4x4, into: &triangles)
        guard !triangles.isEmpty else { throw BIMLoaderError.noGeometry }

        let bvh = BVH(triangles: triangles)
        let bounds = bvh.bounds
        let size = bounds.max - bounds.min
        guard size.max() < implausibleExtentMeters else {
            throw BIMLoaderError.suspiciousScale(size)
        }

        return BIMModel(
            name: url.deletingPathExtension().lastPathComponent,
            entity: entity,
            bvh: bvh,
            triangleCount: triangles.count,
            bounds: bounds
        )
    }

    // MARK: - Triangle extraction

    /// Walks the entity hierarchy, baking each node's transform into its
    /// triangles so the BVH lives in a single flat model space.
    private static func collectTriangles(
        from entity: Entity,
        parentTransform: float4x4,
        into triangles: inout [GPUTriangle]
    ) {
        let worldTransform = parentTransform * entity.transform.matrix

        // The subscript is already generic over the component type and returns
        // `ModelComponent?`; casting it again is redundant and does not compile
        // against current RealityKit.
        if let model = entity.components[ModelComponent.self] {
            append(mesh: model.mesh, transform: worldTransform, into: &triangles)
        }
        for child in entity.children {
            collectTriangles(from: child, parentTransform: worldTransform, into: &triangles)
        }
    }

    private static func append(
        mesh: MeshResource,
        transform: float4x4,
        into triangles: inout [GPUTriangle]
    ) {
        let contents = mesh.contents

        // A MeshResource may instance the same model geometry several times with
        // different transforms — common for repeated BIM families such as columns
        // or door sets. Each instance has to be baked out separately.
        var instancesByModel: [String: [float4x4]] = [:]
        for instance in contents.instances {
            instancesByModel[instance.model, default: []].append(instance.transform)
        }

        for model in contents.models {
            let instanceTransforms = instancesByModel[model.id] ?? [matrix_identity_float4x4]

            for part in model.parts {
                let positions = part.positions.elements
                guard let indices = part.triangleIndices?.elements, indices.count >= 3 else { continue }

                for instanceTransform in instanceTransforms {
                    let full = transform * instanceTransform
                    triangles.reserveCapacity(triangles.count + indices.count / 3)

                    var i = 0
                    while i + 2 < indices.count {
                        let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                        i += 3
                        guard a < positions.count, b < positions.count, c < positions.count else { continue }

                        let p0 = full.transformPoint(positions[a])
                        let p1 = full.transformPoint(positions[b])
                        let p2 = full.transformPoint(positions[c])

                        // Drop slivers: they contribute nothing but numerical
                        // noise to closest-point queries and normal estimates.
                        let area = length(cross(p1 - p0, p2 - p0)) * 0.5
                        guard area > 1e-9 else { continue }

                        triangles.append(GPUTriangle(p0, p1, p2))
                    }
                }
            }
        }
    }
}
