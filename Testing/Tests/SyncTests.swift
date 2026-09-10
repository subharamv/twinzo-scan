import XCTest
import simd
@testable import TwinzoCore

/// The wire format is a contract with a database that a phone talks to over a
/// connection that mostly does not work. Two things have to hold: what is encoded
/// means what the schema thinks it means, and nothing an inspector recorded is
/// lost when the upload fails — which, on a construction site, is the normal case.
final class SyncTests: XCTestCase {

    // MARK: - Transform round trip

    /// simd is column-major and every non-Swift consumer of this field reads it
    /// row by row. A transposed transform still renders, still inverts, and is
    /// wrong in a way that shows up as a building placed plausibly but incorrectly.
    func testTransformRoundTripsThroughRowMajor() throws {
        let original = SyntheticScene.transform(
            yaw: 0.61, pitch: -0.24, translation: SIMD3(12.5, -3.25, 7.75))

        let wire = original.rowMajorArray
        let restored = try XCTUnwrap(float4x4.fromRowMajor(wire))

        XCTAssertLessThan(
            SyntheticScene.maximumDisplacement(original, restored,
                                               over: SyntheticScene.probeCorners()),
            1e-4)
    }

    /// Pins the layout itself, so a "tidy-up" that swaps rows for columns fails
    /// here rather than in a viewer three services away.
    func testRowMajorPutsTranslationInTheFourthColumn() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(1, 2, 3, 1)

        let wire = transform.rowMajorArray
        XCTAssertEqual(wire[3], 1, accuracy: 1e-9)    // row 0, column 3
        XCTAssertEqual(wire[7], 2, accuracy: 1e-9)    // row 1, column 3
        XCTAssertEqual(wire[11], 3, accuracy: 1e-9)   // row 2, column 3
        XCTAssertEqual(wire[15], 1, accuracy: 1e-9)
    }

    func testMalformedTransformIsRejectedRatherThanTrapping() {
        XCTAssertNil(float4x4.fromRowMajor([]))
        XCTAssertNil(float4x4.fromRowMajor([1, 2, 3]))
        XCTAssertNil(float4x4.fromRowMajor(Array(repeating: 0, count: 17)))
    }

    // MARK: - Status vocabulary

    /// These strings are MySQL ENUM members. A mismatch is not a compile error
    /// and not a test failure anywhere else — it is a rejected INSERT in
    /// production, after the inspection is over.
    func testStatusWireValuesMatchTheDatabaseEnum() {
        XCTAssertEqual(ElementStatus.pass.wireValue, "pass")
        XCTAssertEqual(ElementStatus.fail.wireValue, "fail")
        XCTAssertEqual(ElementStatus.insufficientData.wireValue, "insufficient_data")
        XCTAssertEqual(ElementStatus.unverified.wireValue, "unverified")

        XCTAssertEqual(RegistrationFit.DegreesOfFreedom.full.wireValue, "full")
        XCTAssertEqual(RegistrationFit.DegreesOfFreedom.gravityConstrained.wireValue,
                       "gravity_constrained")
        XCTAssertEqual(RegistrationFit.DegreesOfFreedom.translationOnly.wireValue,
                       "translation_only")
    }

    // MARK: - Inspection payloads

    private func inspection(
        status: ElementStatus, samples: Int, offset: SIMD3<Float> = .zero
    ) -> ElementInspection {
        var accumulator = ElementAccumulator()
        for _ in 0..<samples {
            accumulator.add(signed: 0.019, delta: offset, position: SIMD3(1, 2, 3),
                            toWorld: matrix_identity_float4x4, tolerance: 0.025)
        }
        var element = BIMElement.placeholder(index: 7, name: "C-12")
        element.ifcGuid = "1aBc0De7F9gHiJkLmNoPqR"
        return ElementInspection(element: element, accumulator: accumulator,
                                 coverage: 0.83, tolerance: 0.025, status: status)
    }

    func testMeasuredInspectionCarriesItsAxes() {
        let payload = ElementInspectionPayload(
            inspection(status: .fail, samples: 40, offset: SIMD3(0.004, -0.006, 0.018)))

        XCTAssertEqual(payload.elementIndex, 7)
        XCTAssertEqual(payload.ifcGuid, "1aBc0De7F9gHiJkLmNoPqR")
        XCTAssertEqual(payload.status, "fail")
        XCTAssertEqual(payload.meanDxM ?? 0, 0.004, accuracy: 1e-6)
        XCTAssertEqual(payload.meanDyM ?? 0, -0.006, accuracy: 1e-6)
        XCTAssertEqual(payload.meanDzM ?? 0, 0.018, accuracy: 1e-6)
        XCTAssertEqual(payload.worst?.count, 3)
    }

    /// The important one. A zero deviation on an element nobody scanned is a
    /// measurement claim, and sending zeros instead of nulls would put that claim
    /// into the database where a report would later read it as a pass.
    func testUnverifiedInspectionSendsNullsNotZeros() {
        let payload = ElementInspectionPayload(inspection(status: .unverified, samples: 0))

        XCTAssertEqual(payload.status, "unverified")
        XCTAssertEqual(payload.sampleCount, 0)
        XCTAssertNil(payload.meanAbsM)
        XCTAssertNil(payload.meanSignedM)
        XCTAssertNil(payload.maxAbsM)
        XCTAssertNil(payload.meanDxM)
        XCTAssertNil(payload.worst)
        XCTAssertNil(payload.worstSignedM)
    }

    func testPayloadSurvivesAnEncodeDecodeRoundTrip() throws {
        let upload = SessionUpload(
            clientChangeID: UUID(),
            deviceID: "iphone-A1B2C3",
            session: ScanSessionPayload(
                id: UUID(), projectID: UUID(), modelVersionID: "R3",
                name: "Bay 4", deviceModel: "iPhone15,3", osVersion: "17.5.1",
                appVersion: "0.2.0", startedAt: Date(timeIntervalSince1970: 1_700_000_000.25),
                endedAt: nil, minDepthConfidence: 1, voxelSizeM: 0.05,
                scanPointCount: 58432, meshAnchorCount: 96),
            registrations: [
                RegistrationPayload(
                    id: UUID(), scanSessionID: UUID(), sequenceNo: 1,
                    method: AlignmentMethod.controlPointsThenICP.wireValue,
                    worldToModel: matrix_identity_float4x4.rowMajorArray,
                    appliedScale: 1, rmsErrorM: 0.0081, inlierRatio: 0.74,
                    degreesOfFreedom: "full", warnings: ["a warning"],
                    establishedAt: Date(timeIntervalSince1970: 1_700_000_100.5),
                    controlPoints: [
                        ControlPointPayload(label: "grid B/3", world: [1, 0, 4],
                                            model: [2, 0, 7], elementIndex: 7,
                                            residualM: 0.006),
                    ]),
            ],
            inspections: [ElementInspectionPayload(
                inspection(status: .fail, samples: 40, offset: SIMD3(0.004, -0.006, 0.018)))],
            coverage: CoveragePayload(sampleSpacingM: 0.1, searchRadiusM: 0.094,
                                      coveredAreaM2: 53.9, totalAreaM2: 68.9),
            drift: [DriftSamplePayload(measuredAt: Date(timeIntervalSince1970: 1_700_000_200),
                                       displacementM: 0.041, rmsErrorM: 0.0129,
                                       corrected: true)],
            summary: SummaryPayload(pass: 1, fail: 1, insufficient: 0, unverified: 1))

        let data = try SyncCoding.makeEncoder().encode(upload)
        let restored = try SyncCoding.makeDecoder().decode(SessionUpload.self, from: data)
        XCTAssertEqual(upload, restored)
    }

    /// Two mesh chunks can be evaluated inside the same second and their order is
    /// part of the evidence, so the timestamp format has to keep milliseconds.
    func testTimestampsKeepSubSecondPrecision() throws {
        let precise = Date(timeIntervalSince1970: 1_700_000_000.123)
        let sample = DriftSamplePayload(measuredAt: precise, displacementM: 0.01,
                                        rmsErrorM: nil, corrected: false)

        let data = try SyncCoding.makeEncoder().encode(sample)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(".123"), "Lost sub-second precision: \(text)")

        let restored = try SyncCoding.makeDecoder().decode(DriftSamplePayload.self, from: data)
        XCTAssertEqual(restored.measuredAt.timeIntervalSince1970,
                       precise.timeIntervalSince1970, accuracy: 0.002)
    }

    // MARK: - Outbox

    private func makeOutbox(_ name: String = UUID().uuidString) -> SyncOutbox {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("twinzo-tests/\(name).json")
        try? FileManager.default.removeItem(at: url)
        return SyncOutbox(fileURL: url)
    }

    func testQueuedWorkSurvivesRelaunch() {
        let name = UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("twinzo-tests/\(name).json")
        try? FileManager.default.removeItem(at: url)

        let id = UUID()
        do {
            let outbox = SyncOutbox(fileURL: url)
            outbox.enqueue(Data("an afternoon of work".utf8), id: id)
            XCTAssertEqual(outbox.count, 1)
        }

        // A fresh instance, as after the app is killed and reopened.
        let reopened = SyncOutbox(fileURL: url)
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.nextDue()?.id, id)
    }

    func testSuccessRemovesTheEntry() {
        let outbox = makeOutbox()
        let entry = outbox.enqueue(Data([1, 2, 3]))
        outbox.markSucceeded(id: entry.id)
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertNil(outbox.nextDue())
    }

    /// A failed upload must stay queued. Losing it would lose the inspection.
    func testFailureKeepsTheEntryAndRecordsWhy() {
        let outbox = makeOutbox()
        let entry = outbox.enqueue(Data([1]))
        outbox.markFailed(id: entry.id, error: "offline")

        XCTAssertEqual(outbox.count, 1)
        let stored = outbox.nextDue(now: Date().addingTimeInterval(3600))
        XCTAssertEqual(stored?.attempts, 1)
        XCTAssertEqual(stored?.lastError, "offline")
    }

    /// Backoff, or a phone with no signal spends the afternoon retrying and is
    /// flat before anyone reaches the car park.
    func testBackoffDelaysTheNextAttempt() {
        let outbox = makeOutbox()
        let entry = outbox.enqueue(Data([1]))
        let failedAt = Date()
        outbox.markFailed(id: entry.id, error: "timeout", at: failedAt)

        XCTAssertNil(outbox.nextDue(now: failedAt.addingTimeInterval(1)),
                     "Must not retry immediately after a failure")
        XCTAssertNotNil(outbox.nextDue(now: failedAt.addingTimeInterval(60)))
    }

    func testBackoffIsCapped() {
        var entry = OutboxEntry(id: UUID(), payload: Data(), queuedAt: Date(),
                                attempts: 40, lastAttemptAt: Date(), lastError: nil)
        // Uncapped, 2^40 seconds is about thirty-five thousand years.
        XCTAssertTrue(entry.nextAttemptDue(now: Date().addingTimeInterval(901)))
        entry.attempts = 1
        XCTAssertFalse(entry.nextAttemptDue(now: Date().addingTimeInterval(1)))
    }

    /// An entry the server keeps rejecting is both a bug worth diagnosing and
    /// somebody's afternoon of work. It stops being retried; it is never dropped.
    func testPoisonedEntriesAreSetAsideNotDiscarded() {
        let outbox = makeOutbox()
        let entry = outbox.enqueue(Data([1]))
        var when = Date()
        for _ in 0..<SyncOutbox.maximumAttempts {
            when = when.addingTimeInterval(1000)
            outbox.markFailed(id: entry.id, error: "500", at: when)
        }

        XCTAssertNil(outbox.nextDue(now: when.addingTimeInterval(10_000)),
                     "A poisoned entry stops being retried")
        XCTAssertEqual(outbox.count, 1, "...but is still there")
        XCTAssertEqual(outbox.poisoned.count, 1)
        XCTAssertEqual(outbox.pendingCount, 0)

        outbox.retryPoisoned()
        XCTAssertNotNil(outbox.nextDue())
    }

    func testOverflowTrimsPendingWorkBeforePoisonedWork() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("twinzo-tests/\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        let outbox = SyncOutbox(fileURL: url, maximumEntries: 3)

        let poisoned = outbox.enqueue(Data([0]))
        var when = Date()
        for _ in 0..<SyncOutbox.maximumAttempts {
            when = when.addingTimeInterval(1000)
            outbox.markFailed(id: poisoned.id, error: "500", at: when)
        }
        for i in 1...5 { outbox.enqueue(Data([UInt8(i)])) }

        XCTAssertEqual(outbox.count, 3)
        XCTAssertEqual(outbox.poisoned.count, 1,
                       "The entry somebody has to look at must not be the one thrown away")
    }

    /// A truncated queue file must not stop the app launching. Losing unsent work
    /// is bad; refusing to start so it can never be replaced is worse.
    func testCorruptQueueFileDoesNotPreventLaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("twinzo-tests/\(UUID().uuidString).json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        let outbox = SyncOutbox(fileURL: url)
        XCTAssertTrue(outbox.isEmpty)
        outbox.enqueue(Data([9]))
        XCTAssertEqual(SyncOutbox(fileURL: url).count, 1)
    }
}
