import XCTest
import simd
@testable import TwinzoCore

/// The PLY export is the artefact an engineer disputing a finding will open in
/// CloudCompare, so a malformed header or a byte-offset slip discredits the
/// measurement rather than defending it. Binary formats fail silently — a reader
/// will happily interpret shifted bytes as coordinates — so the bytes are
/// checked here rather than eyeballed.
final class PointCloudPLYTests: XCTestCase {

    /// Splits a PLY into its ASCII header and the binary payload after it.
    private func split(_ data: Data) -> (header: String, body: Data)? {
        let terminator = Data("end_header\n".utf8)
        guard let range = data.range(of: terminator) else { return nil }
        let header = String(decoding: data[..<range.upperBound], as: UTF8.self)
        return (header, data[range.upperBound...])
    }

    func testHeaderDeclaresTheVertexCountActuallyWritten() {
        let points = (0..<7).map { SIMD3<Float>(Float($0), 0, 0) }
        let data = PointCloudPLY.data(
            points: points,
            confidences: [UInt8](repeating: 2, count: points.count),
            worldToModel: matrix_identity_float4x4,
            comment: "count check"
        )

        guard let (header, body) = split(data) else {
            return XCTFail("No end_header terminator")
        }
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        XCTAssertTrue(header.contains("element vertex 7"))
        // Three floats plus one confidence byte per vertex, packed.
        XCTAssertEqual(body.count, 7 * 13, "Header count and payload length disagree")
    }

    func testCoordinatesRoundTripThroughTheBinaryPayload() {
        // Deliberately awkward values: an ASCII exporter using %f would round
        // the third of these away entirely.
        let points: [SIMD3<Float>] = [
            SIMD3(1.5, -2.25, 3.125),
            SIMD3(-0.0009765625, 1e-4, 12345.678),
        ]
        let data = PointCloudPLY.data(
            points: points,
            confidences: [0, 1],
            worldToModel: matrix_identity_float4x4,
            comment: "round trip"
        )
        guard let (_, body) = split(data) else { return XCTFail("No end_header terminator") }

        for (index, expected) in points.enumerated() {
            let offset = body.startIndex + index * 13
            let x = Float(bitPattern: UInt32(littleEndian: body.load(at: offset)))
            let y = Float(bitPattern: UInt32(littleEndian: body.load(at: offset + 4)))
            let z = Float(bitPattern: UInt32(littleEndian: body.load(at: offset + 8)))
            XCTAssertEqual(x, expected.x, "x differs at point \(index)")
            XCTAssertEqual(y, expected.y, "y differs at point \(index)")
            XCTAssertEqual(z, expected.z, "z differs at point \(index)")
            XCTAssertEqual(body[offset + 12], index == 0 ? 0 : 1,
                           "Confidence byte landed at the wrong offset")
        }
    }

    func testPointsAreWrittenInModelSpaceNotWorldSpace() {
        // The whole point of exporting through worldToModel is that the cloud
        // opens on top of the BIM model rather than beside it.
        var worldToModel = matrix_identity_float4x4
        worldToModel.columns.3 = SIMD4<Float>(-10, -20, -30, 1)

        let data = PointCloudPLY.data(
            points: [SIMD3(10, 20, 30)],
            confidences: [2],
            worldToModel: worldToModel,
            comment: "transform"
        )
        guard let (header, body) = split(data) else { return XCTFail("No end_header terminator") }
        XCTAssertTrue(header.contains("model space"), "Header should say which frame it is in")

        let x = Float(bitPattern: UInt32(littleEndian: body.load(at: body.startIndex)))
        let y = Float(bitPattern: UInt32(littleEndian: body.load(at: body.startIndex + 4)))
        let z = Float(bitPattern: UInt32(littleEndian: body.load(at: body.startIndex + 8)))
        XCTAssertEqual(x, 0, accuracy: 1e-6)
        XCTAssertEqual(y, 0, accuracy: 1e-6)
        XCTAssertEqual(z, 0, accuracy: 1e-6)
    }

    func testCommentNewlinesCannotBreakTheHeader() {
        // A model named across two lines would otherwise terminate the comment
        // and leave a stray line the reader treats as an unknown element.
        let data = PointCloudPLY.data(
            points: [SIMD3(0, 0, 0)],
            confidences: [2],
            worldToModel: matrix_identity_float4x4,
            comment: "bay\nelement vertex 999999\r injected"
        )
        guard let (header, _) = split(data) else { return XCTFail("No end_header terminator") }

        // The injected text may survive inside the comment — a comment is free
        // text and a reader ignores it. What must not survive is a second *line*
        // the reader would parse as an element declaration.
        let declarations = header
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("element vertex") }
        XCTAssertEqual(declarations, ["element vertex 1"],
                       "A newline in the comment escaped into the header structure")
    }

    func testEmptyCloudStillProducesAReadableFile() {
        let data = PointCloudPLY.data(
            points: [], confidences: [],
            worldToModel: matrix_identity_float4x4, comment: "empty"
        )
        guard let (header, body) = split(data) else { return XCTFail("No end_header terminator") }
        XCTAssertTrue(header.contains("element vertex 0"))
        XCTAssertEqual(body.count, 0)
    }
}

private extension Data {
    /// Reads a little-endian UInt32 at an absolute index, without assuming the
    /// slice's indices start at zero.
    func load(at index: Index) -> UInt32 {
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(self[index + byte]) << (8 * UInt32(byte))
        }
        return value
    }
}
