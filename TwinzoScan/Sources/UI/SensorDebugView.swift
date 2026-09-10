import SwiftUI

/// Debug overlay showing real-time sensor data.
struct SensorDebugView: View {
    @ObservedObject var monitor: SensorMonitor
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Header - more compact
                    HStack(spacing: 6) {
                        Image(systemName: "sensor.fill")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text("Sensors")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    
                    Divider()
                    
                    // Gyroscope - compact layout
                    CompactSensorSection(
                        title: "Gyro",
                        icon: "gyroscope",
                        unit: "rad/s",
                        isAvailable: monitor.isGyroAvailable,
                        x: monitor.gyroX,
                        y: monitor.gyroY,
                        z: monitor.gyroZ
                    )
                    
                    Divider().padding(.vertical, 2)
                    
                    // Accelerometer - compact layout
                    CompactSensorSection(
                        title: "Accel",
                        icon: "arrow.up.down.square",
                        unit: "G",
                        isAvailable: monitor.isAccelAvailable,
                        x: monitor.accelX,
                        y: monitor.accelY,
                        z: monitor.accelZ
                    )
                    
                    Divider().padding(.vertical, 2)
                    
                    // Magnetometer - compact with status
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "location.north.circle")
                                .font(.caption2)
                                .foregroundStyle(monitor.isMagnetometerAvailable ? .green : .red)
                            Text("Mag")
                                .font(.caption.weight(.semibold))
                            if monitor.isMagnetometerAvailable {
                                Text("(\(magnetometerAccuracyShort(monitor.magnetometerAccuracy)))")
                                    .font(.system(size: 9))
                                    .foregroundStyle(magnetometerAccuracyColor(monitor.magnetometerAccuracy))
                            }
                        }
                        
                        if monitor.isMagnetometerAvailable {
                            HStack(spacing: 6) {
                                CompactValue(label: "X", value: monitor.magnetometerX, unit: "μT")
                                CompactValue(label: "Y", value: monitor.magnetometerY, unit: "μT")
                                CompactValue(label: "Z", value: monitor.magnetometerZ, unit: "μT")
                            }
                        }
                    }
                    
                    Divider().padding(.vertical, 2)
                    
                    // Device Attitude - compact
                    if monitor.isDeviceMotionAvailable {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Image(systemName: "rotate.3d")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                                Text("Attitude")
                                    .font(.caption.weight(.semibold))
                            }
                            
                            HStack(spacing: 6) {
                                CompactValue(label: "Head", value: monitor.heading, unit: "°")
                                CompactValue(label: "Pitch", value: monitor.pitch, unit: "°")
                                CompactValue(label: "Roll", value: monitor.roll, unit: "°")
                            }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 280) // Limit height to avoid covering too much
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
    
    // MARK: - Helper Methods
    
    private func magnetometerAccuracyShort(_ accuracy: Int32) -> String {
        switch accuracy {
        case -1: return "Uncal"
        case 0: return "Low"
        case 1: return "Med"
        case 2: return "High"
        default: return "?"
        }
    }
    
    private func magnetometerAccuracyColor(_ accuracy: Int32) -> Color {
        switch accuracy {
        case -1: return .red
        case 0: return .orange
        case 1: return .yellow
        case 2: return .green
        default: return .gray
        }
    }
}

// MARK: - Compact Components

private struct CompactSensorSection: View {
    let title: String
    let icon: String
    let unit: String
    let isAvailable: Bool
    let x: Double
    let y: Double
    let z: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(isAvailable ? .green : .red)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            
            if isAvailable {
                HStack(spacing: 6) {
                    CompactValue(label: "X", value: x, unit: unit)
                    CompactValue(label: "Y", value: y, unit: unit)
                    CompactValue(label: "Z", value: z, unit: unit)
                }
            }
        }
    }
}

private struct CompactValue: View {
    let label: String
    let value: Double
    let unit: String
    
    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(colorForValue(value))
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func colorForValue(_ value: Double) -> Color {
        let absValue = abs(value)
        if absValue < 0.01 {
            return .primary
        } else if absValue < 0.5 {
            return .green
        } else if absValue < 1.0 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SensorDebugView(monitor: SensorMonitor())
    }
}
