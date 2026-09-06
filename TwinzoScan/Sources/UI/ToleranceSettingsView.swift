import SwiftUI
import UIKit

/// Inspection thresholds and display options.
///
/// These are exposed rather than hard-coded because a single tolerance is never
/// right across a whole building: structural steel, MEP routing and architectural
/// finishes are each signed off against different limits.
struct ToleranceSettingsView: View {

    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss

    /// Held rather than recomputed per redraw: serialising tens of thousands of
    /// points is not something to do on every body evaluation.
    @State private var exportedCloud: URL?
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("Pass/fail", value: $session.tolerances.tolerance,
                           range: 0.005...0.100, step: 0.005)
                    slider("Ramp saturates at", value: $session.tolerances.saturation,
                           range: 0.050...0.500, step: 0.010)
                    slider("Ignore beyond", value: $session.tolerances.rejection,
                           range: 0.200...2.000, step: 0.050)
                } header: {
                    Text("Tolerances")
                } footer: {
                    Text("Surface further than the ignore distance from any modelled "
                       + "element is treated as clutter — pallets, people, temporary "
                       + "works — rather than as a defect.")
                }

                Section("Presets") {
                    preset("Structural", .structural)
                    preset("MEP / services", .mep)
                    preset("Architectural finish", .finishes)
                }

                Section {
                    Picker("Minimum confidence", selection: $session.minimumDepthConfidence) {
                        Text("Low").tag(UInt8(0))
                        Text("Medium").tag(UInt8(1))
                        Text("High").tag(UInt8(2))
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Sensor")
                } footer: {
                    Text("ARKit scores every depth return. Dark, glossy and distant "
                       + "surfaces score low, and admitting them manufactures "
                       + "deviations that look exactly like real ones. Raise this "
                       + "on reflective plant; lower it only if the scan will not "
                       + "build at all.")
                }

                Section("Display") {
                    Toggle("Show passing surface", isOn: $session.showInToleranceSurface)
                    Toggle("Ghost the BIM model", isOn: $session.ghostModel)
                }

                Section {
                    if let cloud = exportedCloud {
                        ShareLink(item: cloud, preview: SharePreview("Scan point cloud")) {
                            Label("Share \(session.scanPointCount) points as PLY",
                                  systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            do {
                                exportedCloud = try session.exportScanCloud()
                                exportError = nil
                            } catch {
                                exportError = error.localizedDescription
                            }
                        } label: {
                            Label("Prepare point cloud export",
                                  systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .disabled(session.scanPointCount == 0)
                    }
                    if let exportError {
                        Text(exportError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Scan cloud")
                } footer: {
                    Text("Binary PLY in model coordinates, with each point's sensor "
                       + "confidence alongside it, so a disputed finding can be "
                       + "re-checked in CloudCompare or Recap against the same "
                       + "measurement the app used. Writing it takes a moment.")
                }

                if !session.defects.defects.isEmpty {
                    Section {
                        ForEach(session.defects.defects.prefix(10)) { defect in
                            HStack {
                                Image(systemName: defect.isProud
                                      ? "arrow.up.right.circle.fill"
                                      : "arrow.down.left.circle.fill")
                                    .foregroundStyle(defect.isProud ? .red : .blue)
                                Text(String(format: "%.0f mm %@",
                                            defect.magnitudeMillimetres,
                                            defect.isProud ? "proud" : "recessed"))
                                Spacer()
                                Text(modelCoordinate(defect))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ShareLink(
                            item: session.defects.exportCSV(
                                worldToModel: session.alignment.worldToModel),
                            preview: SharePreview("Deviation findings")
                        ) {
                            Label("Export findings as CSV", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Worst findings")
                    } footer: {
                        Text("One entry per scanned chunk, so the list spreads across the "
                           + "space rather than repeating the same defect. Coordinates are "
                           + "in model space.")
                    }
                }

                Section("Legend") {
                    ForEach(Array(DeviationPalette.bands.enumerated()), id: \.offset) { _, band in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(band.color))
                                .frame(width: 28, height: 16)
                            Text(band.label).font(.callout)
                        }
                    }
                }

                if let model = session.model {
                    Section("Loaded model") {
                        LabeledContent("Name", value: model.name)
                        LabeledContent("Triangles", value: "\(model.triangleCount)")
                        LabeledContent("Extent", value: String(
                            format: "%.1f × %.1f × %.1f m",
                            model.sizeMeters.x, model.sizeMeters.y, model.sizeMeters.z))
                    }
                }

                Section {
                    Button("Clear scan and start over", role: .destructive) {
                        session.resetScan()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Inspection settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func slider(
        _ label: String, value: Binding<Float>,
        range: ClosedRange<Float>, step: Float
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.0f mm", value.wrappedValue * 1000))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func modelCoordinate(_ defect: Defect) -> String {
        let p = session.alignment.worldToModel.transformPoint(defect.worldPosition)
        return String(format: "%.1f, %.1f, %.1f", p.x, p.y, p.z)
    }

    private func preset(_ name: String, _ settings: ToleranceSettings) -> some View {
        Button(name) {
            // Assign once rather than field by field: each assignment re-runs the
            // session's didSet, rebanding every cached overlay.
            session.tolerances = ToleranceSettings(
                tolerance: settings.tolerance,
                saturation: settings.saturation,
                rejection: session.tolerances.rejection
            )
        }
    }
}
