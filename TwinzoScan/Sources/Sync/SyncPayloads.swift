import Foundation
import simd

/// Wire types for the upload API.
///
/// Deliberately separate from the in-memory models rather than making those
/// `Codable` directly. The domain types change shape as the app evolves; the
/// wire format is a contract with a server and a database that cannot. Keeping
/// them apart means a refactor in `ElementInspection` is a compile error in one
/// mapping function instead of a silent change to what gets stored.
///
/// Everything here is plain Foundation and simd so the encoding can be tested
/// off Apple hardware — a sync bug that only appears in the field is expensive to
/// find and worse to diagnose.

/// Metres, as sent. A named alias so the unit is visible at every use site: the
/// app works in metres throughout and the reports are in millimetres, and that
/// conversion is exactly the kind of thing that gets applied twice.
typealias Meters = Double

// MARK: - Session

struct ScanSessionPayload: Codable, Equatable, Sendable {
    var id: UUID
    var projectID: UUID
    var modelVersionID: String?
    var name: String?

    var deviceModel: String?
    var osVersion: String?
    var appVersion: String?

    var startedAt: Date
    var endedAt: Date?

    var minDepthConfidence: Int
    var voxelSizeM: Meters
    var scanPointCount: Int
    var meshAnchorCount: Int
}

// MARK: - Registration

struct RegistrationPayload: Codable, Equatable, Sendable {
    var id: UUID
    var scanSessionID: UUID
    var sequenceNo: Int
    var method: String
    /// Row-major, 16 entries. Row-major on the wire even though simd is
    /// column-major, because every consumer that is not Swift — the database, the
    /// viewer, the report generator — reads it row by row. The conversion happens
    /// once, here, rather than being rediscovered in each of them.
    var worldToModel: [Double]
    var appliedScale: Double
    var rmsErrorM: Meters?
    var inlierRatio: Double?
    var degreesOfFreedom: String?
    var warnings: [String]
    var establishedAt: Date
    var controlPoints: [ControlPointPayload]
}

struct ControlPointPayload: Codable, Equatable, Sendable {
    var label: String?
    var world: [Double]
    var model: [Double]
    var elementIndex: Int?
    var residualM: Meters?
}

// MARK: - Results

struct ElementInspectionPayload: Codable, Equatable, Sendable {
    /// Positional index within the model version. The join key on import.
    var elementIndex: Int
    /// Sent alongside the index so a mismatched model version is detectable at
    /// the server rather than producing findings against the wrong elements.
    var ifcGuid: String?
    var status: String
    var toleranceM: Meters
    var sampleCount: Int
    var inToleranceCount: Int
    var meanAbsM: Meters?
    var meanSignedM: Meters?
    var maxAbsM: Meters?
    var meanDxM: Meters?
    var meanDyM: Meters?
    var meanDzM: Meters?
    var worst: [Double]?
    var worstSignedM: Meters?
    var coverage: Double?
}

struct CoveragePayload: Codable, Equatable, Sendable {
    var sampleSpacingM: Meters
    var searchRadiusM: Meters
    var coveredAreaM2: Double
    var totalAreaM2: Double
}

struct DriftSamplePayload: Codable, Equatable, Sendable {
    var measuredAt: Date
    var displacementM: Meters
    var rmsErrorM: Meters?
    var corrected: Bool
}

/// One complete upload. Sent whole rather than as a stream of row inserts: a
/// half-uploaded inspection is not a smaller inspection, it is a wrong one, and
/// the server applies this in a single transaction.
struct SessionUpload: Codable, Equatable, Sendable {
    /// Generated on the device. The server records it and refuses a replay, so a
    /// retry after a lost response is a no-op rather than a duplicate.
    var clientChangeID: UUID
    var deviceID: String
    var session: ScanSessionPayload
    var registrations: [RegistrationPayload]
    var inspections: [ElementInspectionPayload]
    var coverage: CoveragePayload?
    var drift: [DriftSamplePayload]

    /// Session-level roll-up, recomputed server-side but sent so a mismatch
    /// between what the device showed the inspector and what the server derives
    /// can be detected rather than silently reconciled.
    var summary: SummaryPayload
}

struct SummaryPayload: Codable, Equatable, Sendable {
    var pass: Int
    var fail: Int
    var insufficient: Int
    var unverified: Int
}

// MARK: - Coding

enum SyncCoding {

    /// One encoder configuration, shared.
    ///
    /// ISO-8601 with fractional seconds because two mesh chunks can be evaluated
    /// inside the same second and their ordering is part of the evidence. Sorted
    /// keys because a byte-identical payload for identical input makes the outbox
    /// deduplicable and the wire traffic diffable.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(iso8601)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(iso8601)
        return decoder
    }

    static let iso8601: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }()
}

// MARK: - Mapping

extension SIMD3 where Scalar == Float {
    var wireArray: [Double] { [Double(x), Double(y), Double(z)] }
}

extension float4x4 {
    /// Row-major flattening for the wire. simd stores columns, so this is a
    /// transpose, and getting it backwards produces a transform that is subtly
    /// wrong in a way that still renders.
    var rowMajorArray: [Double] {
        let c = (columns.0, columns.1, columns.2, columns.3)
        return [
            Double(c.0.x), Double(c.1.x), Double(c.2.x), Double(c.3.x),
            Double(c.0.y), Double(c.1.y), Double(c.2.y), Double(c.3.y),
            Double(c.0.z), Double(c.1.z), Double(c.2.z), Double(c.3.z),
            Double(c.0.w), Double(c.1.w), Double(c.2.w), Double(c.3.w),
        ]
    }

    /// Inverse of `rowMajorArray`. Returns nil for anything but 16 entries
    /// rather than trapping: this reads data that came off a network.
    static func fromRowMajor(_ values: [Double]) -> float4x4? {
        guard values.count == 16 else { return nil }
        func at(_ row: Int, _ column: Int) -> Float { Float(values[row * 4 + column]) }
        return float4x4(
            SIMD4(at(0, 0), at(1, 0), at(2, 0), at(3, 0)),
            SIMD4(at(0, 1), at(1, 1), at(2, 1), at(3, 1)),
            SIMD4(at(0, 2), at(1, 2), at(2, 2), at(3, 2)),
            SIMD4(at(0, 3), at(1, 3), at(2, 3), at(3, 3))
        )
    }
}

extension ElementStatus {
    /// Snake case, matching the MySQL ENUM exactly. Written out rather than
    /// derived so a rename of the Swift case cannot silently change what is
    /// stored — the database would reject the new value, but only in production.
    var wireValue: String {
        switch self {
        case .pass:             return "pass"
        case .fail:             return "fail"
        case .insufficientData: return "insufficient_data"
        case .unverified:       return "unverified"
        }
    }
}

extension AlignmentMethod {
    var wireValue: String {
        switch self {
        case .manual:               return "manual"
        case .controlPoints:        return "control_points"
        case .icp:                  return "icp"
        case .controlPointsThenICP: return "control_points_then_icp"
        }
    }
}

extension RegistrationFit.DegreesOfFreedom {
    var wireValue: String {
        switch self {
        case .full:               return "full"
        case .gravityConstrained: return "gravity_constrained"
        case .translationOnly:    return "translation_only"
        }
    }
}

extension ElementInspectionPayload {
    /// Builds a payload from a finished inspection.
    ///
    /// Unmeasured elements send nulls rather than zeros. A zero deviation on an
    /// element nobody scanned is a measurement claim, and the whole point of
    /// carrying `unverified` through to the database is to avoid making it.
    init(_ inspection: ElementInspection) {
        let measured = inspection.accumulator.sampleCount > 0
        self.init(
            elementIndex: Int(inspection.element.index),
            ifcGuid: inspection.element.ifcGuid,
            status: inspection.status.wireValue,
            toleranceM: Double(inspection.tolerance),
            sampleCount: inspection.accumulator.sampleCount,
            inToleranceCount: inspection.accumulator.inToleranceCount,
            meanAbsM: measured ? Double(inspection.meanAbsolute) : nil,
            meanSignedM: measured ? Double(inspection.meanSigned) : nil,
            maxAbsM: measured ? Double(inspection.maxAbsolute) : nil,
            meanDxM: measured ? Double(inspection.meanOffset.x) : nil,
            meanDyM: measured ? Double(inspection.meanOffset.y) : nil,
            meanDzM: measured ? Double(inspection.meanOffset.z) : nil,
            worst: measured ? inspection.accumulator.worstWorldPosition.wireArray : nil,
            worstSignedM: measured ? Double(inspection.accumulator.worstSigned) : nil,
            coverage: inspection.coverage.map(Double.init)
        )
    }
}

extension CoveragePayload {
    init(_ report: CoverageReport, searchRadius: Float) {
        self.init(
            sampleSpacingM: Double(report.spacing),
            searchRadiusM: Double(searchRadius),
            coveredAreaM2: Double(report.coveredArea),
            totalAreaM2: Double(report.totalArea)
        )
    }
}

extension SummaryPayload {
    init(_ summary: InspectionSummary) {
        self.init(pass: summary.pass, fail: summary.fail,
                  insufficient: summary.insufficient, unverified: summary.unverified)
    }
}
