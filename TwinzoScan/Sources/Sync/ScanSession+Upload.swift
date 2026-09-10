import Foundation
import UIKit
import simd

extension ScanSession {

    /// Assembles everything this session measured into one uploadable payload.
    ///
    /// Built whole and sent in one transaction. A half-uploaded inspection is not
    /// a smaller inspection — it is a wrong one, because the pass rate would be
    /// computed over the elements that happened to arrive.
    ///
    /// Every element is included, `unverified` ones especially. The temptation is
    /// to send only what was measured and save the bandwidth; the cost is a
    /// database that cannot distinguish a building nobody inspected from one with
    /// no defects.
    func makeUpload(projectID: UUID, deviceID: String, sessionID: UUID,
                    startedAt: Date) -> SessionUpload? {
        guard let model else { return nil }

        let inspections = elementInspections.map(ElementInspectionPayload.init)

        var registrations: [RegistrationPayload] = []
        if let quality = alignment.state.quality {
            registrations.append(RegistrationPayload(
                id: UUID(),
                scanSessionID: sessionID,
                sequenceNo: 1,
                method: quality.method.wireValue,
                worldToModel: alignment.worldToModel.rowMajorArray,
                appliedScale: Double(quality.scale),
                rmsErrorM: Double(quality.rmsError),
                // Zero means "not applicable" for a target fit, where every pair
                // is used by construction. Sending it as a measured 0% would
                // read as a registration that matched nothing.
                inlierRatio: quality.inlierRatio > 0 ? Double(quality.inlierRatio) : nil,
                degreesOfFreedom: quality.degreesOfFreedom?.wireValue,
                warnings: alignment.registrationWarnings,
                establishedAt: quality.establishedAt,
                controlPoints: alignment.controlPoints.map { pair in
                    ControlPointPayload(
                        label: pair.label.isEmpty ? nil : pair.label,
                        world: pair.worldPoint.wireArray,
                        model: pair.modelPoint.wireArray,
                        elementIndex: pair.elementIndex.map(Int.init),
                        residualM: nil
                    )
                }
            ))
        }

        let bundle = Bundle.main.infoDictionary
        let session = ScanSessionPayload(
            id: sessionID,
            projectID: projectID,
            modelVersionID: model.modelVersionID,
            name: model.name,
            deviceModel: Self.hardwareIdentifier,
            osVersion: UIDevice.current.systemVersion,
            appVersion: bundle?["CFBundleShortVersionString"] as? String,
            startedAt: startedAt,
            endedAt: Date(),
            minDepthConfidence: Int(minimumDepthConfidence),
            voxelSizeM: Double(Self.scanVoxelSize),
            scanPointCount: scanPointCount,
            meshAnchorCount: meshAnchorCount
        )

        return SessionUpload(
            clientChangeID: UUID(),
            deviceID: deviceID,
            session: session,
            registrations: registrations,
            inspections: inspections,
            coverage: coverage.map {
                CoveragePayload($0, searchRadius:
                    CoverageAnalyzer.Parameters.forVoxelSize(Self.scanVoxelSize).searchRadius)
            },
            drift: alignment.driftHistory.map {
                DriftSamplePayload(measuredAt: $0.timestamp,
                                   displacementM: Double($0.displacementMeters),
                                   rmsErrorM: Double($0.rmsError),
                                   corrected: $0.corrected)
            },
            summary: SummaryPayload(inspectionSummary)
        )
    }

    /// The machine identifier, e.g. `iPhone15,3`.
    ///
    /// `UIDevice.model` returns "iPhone", which is useless here: LiDAR range and
    /// noise differ measurably between generations, and a disputed finding will
    /// be argued on exactly which phone took it.
    static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafePointer(to: machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self,
                                      capacity: MemoryLayout.size(ofValue: machine)) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}
