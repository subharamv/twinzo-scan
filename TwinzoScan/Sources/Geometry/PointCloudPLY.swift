import Foundation
import simd

/// Serialises the accumulated scan as a PLY point cloud.
///
/// Exists so a finding can be re-checked off the device. The defect CSV says
/// where the app thinks the problems are; this says what it actually measured,
/// which is what an engineer disputing a result will ask for.
///
/// Binary little-endian rather than ASCII: a warehouse bay runs to tens of
/// thousands of points, and the ASCII form is roughly five times the size, loses
/// precision in the round trip through `%f`, and costs a string reallocation per
/// point to build. CloudCompare, MeshLab, Recap and Open3D all read this form.
enum PointCloudPLY {

    /// Bytes per vertex record: three floats plus the confidence byte, packed.
    private static let stride = 13

    /// - Parameters:
    ///   - points: scan points in LiDAR world space.
    ///   - confidences: ARKit depth confidence per point, parallel to `points`.
    ///     `ScanCloud.unknownConfidence` for points never scored.
    ///   - worldToModel: applied on the way out, so the cloud lands in the same
    ///     coordinates as the BIM model and the defect CSV. Pass identity to
    ///     export in world space instead.
    ///   - comment: free text recorded in the header.
    static func data(
        points: [SIMD3<Float>],
        confidences: [UInt8],
        worldToModel: float4x4,
        comment: String
    ) -> Data {
        precondition(points.count == confidences.count,
                     "confidence array must parallel the point array")

        let header = """
        ply
        format binary_little_endian 1.0
        comment \(sanitised(comment))
        comment coordinates are in BIM model space
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar confidence
        end_header

        """

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + points.count * stride)

        // One scratch record reused per point: appending four separate slices per
        // vertex is what makes naive PLY writers slow.
        var record = [UInt8](repeating: 0, count: stride)
        for index in points.indices {
            let p = worldToModel.transformPoint(points[index])
            record.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: p.x.bitPattern.littleEndian, toByteOffset: 0, as: UInt32.self)
                raw.storeBytes(of: p.y.bitPattern.littleEndian, toByteOffset: 4, as: UInt32.self)
                raw.storeBytes(of: p.z.bitPattern.littleEndian, toByteOffset: 8, as: UInt32.self)
                raw.storeBytes(of: confidences[index], toByteOffset: 12, as: UInt8.self)
            }
            data.append(contentsOf: record)
        }
        return data
    }

    /// A header comment must not contain a newline: PLY headers are line-based
    /// and an embedded break would terminate the comment and corrupt the file.
    private static func sanitised(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
