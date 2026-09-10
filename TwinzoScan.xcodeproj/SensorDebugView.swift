import SwiftUI

/// Debug overlay showing real-time sensor data.
struct SensorDebugView: View {
    @ObservedObject var monitor: SensorMonitor
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "sensor.fill")
                        .foregroundStyle(.blue)
                    Text("Sensor Monitor")
                        .font(.headline)
                    Spacer()
                }
                
                Divider()
                
                // Gyroscope
                SensorSection(
                    title: "Gyroscope",
                    icon: "gyroscope",
                    unit: "rad/s",
                    isAvailable: monitor.isGyroAvailable,
                    values: [
                        ("X", monitor.gyroX),
                        ("Y", monitor.gyroY),
                        ("Z", monitor.gyroZ)
                    ]
                )
                
                Divider()
                
                // Accelerometer
                SensorSection(
                    title: "Accelerometer",
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    unit: "G",
                    isAvailable: monitor.isAccelAvailable,
                    values: [
                        ("X", monitor.accelX),
                        ("Y", monitor.accelY),
                        ("Z", monitor.accelZ)
                    ]
                )
                
                Divider()
                
                // Magnetometer
                SensorSection(
                    title: "Magnetometer",
                    icon: "location.north.circle",
                    unit: "μT",
                    isAvailable: monitor.isMagnetometerAvailable,
                    values: [
                        ("X", monitor.magnetometerX),
                        ("Y", monitor.magnetometerY),
                        ("Z", monitor.magnetometerZ)
                    ]
                )
                
                Divider()
                
                // Device Attitude
                if monitor.isDeviceMotionAvailable {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "rotate.3d")
                                .font(.caption)
                                .foregroundStyle(.purple)
                            Text("Attitude")
                                .font(.caption.weight(.semibold))
                        }
                        
                        HStack(spacing: 12) {
                            AttitudeValue(label: "Heading", value: monitor.heading, color: .blue)
                            AttitudeValue(label: "Pitch", value: monitor.pitch, color: .green)
                            AttitudeValue(label: "Roll", value: monitor.roll, color: .orange)
                        }
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Sensor Section

private struct SensorSection: View {
    let title: String
    let icon: String
    let unit: String
    let isAvailable: Bool
    let values: [(String, Double)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(isAvailable ? .green : .red)
                Text(title)
                    .font(.caption.weight(.semibold))
                if !isAvailable {
                    Text("(Unavailable)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            if isAvailable {
                HStack(spacing: 12) {
                    ForEach(values, id: \.0) { label, value in
                        SensorValue(label: label, value: value, unit: unit)
                    }
                }
            }
        }
    }
}

// MARK: - Value Display

private struct SensorValue: View {
    let label: String
    let value: Double
    let unit: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.3f", value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(colorForValue(value))
                Text(unit)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
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

private struct AttitudeValue: View {
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color)
                Text("°")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        SensorDebugView(monitor: SensorMonitor())
    }
}
