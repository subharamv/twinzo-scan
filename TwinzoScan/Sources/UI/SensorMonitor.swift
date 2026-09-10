import Foundation
import CoreMotion
import Combine

/// Monitors device motion sensors and exposes real-time data for debugging.
@MainActor
final class SensorMonitor: ObservableObject {
    
    // MARK: Published sensor data
    
    @Published var gyroX: Double = 0.0
    @Published var gyroY: Double = 0.0
    @Published var gyroZ: Double = 0.0
    
    @Published var accelX: Double = 0.0
    @Published var accelY: Double = 0.0
    @Published var accelZ: Double = 0.0
    
    @Published var magnetometerX: Double = 0.0
    @Published var magnetometerY: Double = 0.0
    @Published var magnetometerZ: Double = 0.0
    @Published var magnetometerAccuracy: Int32 = 0
    
    @Published var heading: Double = 0.0
    @Published var pitch: Double = 0.0
    @Published var roll: Double = 0.0
    
    @Published var isGyroAvailable: Bool = false
    @Published var isAccelAvailable: Bool = false
    @Published var isMagnetometerAvailable: Bool = false
    @Published var isDeviceMotionAvailable: Bool = false
    
    // MARK: Private properties
    
    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 0.1 // 10 Hz for UI updates
    
    // MARK: - Lifecycle
    
    init() {
        checkAvailability()
    }
    
    nonisolated deinit {
        // Stop updates - CMMotionManager methods are thread-safe
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        motionManager.stopMagnetometerUpdates()
    }
    
    // MARK: - Control
    
    func start() {
        // Check what's available
        isGyroAvailable = motionManager.isGyroAvailable
        isAccelAvailable = motionManager.isAccelerometerAvailable
        isMagnetometerAvailable = motionManager.isMagnetometerAvailable
        isDeviceMotionAvailable = motionManager.isDeviceMotionAvailable
        
        // Set update intervals
        motionManager.gyroUpdateInterval = updateInterval
        motionManager.accelerometerUpdateInterval = updateInterval
        motionManager.magnetometerUpdateInterval = updateInterval
        motionManager.deviceMotionUpdateInterval = updateInterval
        
        // Start device motion (combines all sensors) with magnetic field reference
        if motionManager.isDeviceMotionAvailable {
            motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] motion, error in
                guard let self, let motion = motion else { return }
                
                // Gyroscope (rotation rate in rad/s) - apply dead zone for noise
                self.gyroX = self.applyDeadZone(motion.rotationRate.x)
                self.gyroY = self.applyDeadZone(motion.rotationRate.y)
                self.gyroZ = self.applyDeadZone(motion.rotationRate.z)
                
                // Accelerometer (user acceleration without gravity, in G's)
                self.accelX = self.applyDeadZone(motion.userAcceleration.x)
                self.accelY = self.applyDeadZone(motion.userAcceleration.y)
                self.accelZ = self.applyDeadZone(motion.userAcceleration.z)
                
                // Magnetometer (magnetic field in microteslas)
                let magField = motion.magneticField.field
                self.magnetometerX = magField.x
                self.magnetometerY = magField.y
                self.magnetometerZ = magField.z
                self.magnetometerAccuracy = motion.magneticField.accuracy.rawValue
                
                // Attitude (device orientation in space)
                self.heading = motion.attitude.yaw * 180 / .pi
                self.pitch = motion.attitude.pitch * 180 / .pi
                self.roll = motion.attitude.roll * 180 / .pi
            }
        } else {
            // Fall back to individual sensors if device motion not available
            startIndividualSensors()
        }
    }
    
    // Apply dead zone to filter out sensor noise when device is static
    private func applyDeadZone(_ value: Double, threshold: Double = 0.005) -> Double {
        return abs(value) < threshold ? 0.0 : value
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        motionManager.stopMagnetometerUpdates()
    }
    
    // MARK: - Private methods
    
    private func checkAvailability() {
        isGyroAvailable = motionManager.isGyroAvailable
        isAccelAvailable = motionManager.isAccelerometerAvailable
        isMagnetometerAvailable = motionManager.isMagnetometerAvailable
        isDeviceMotionAvailable = motionManager.isDeviceMotionAvailable
    }
    
    private func startIndividualSensors() {
        // Gyroscope
        if motionManager.isGyroAvailable {
            motionManager.startGyroUpdates(to: .main) { [weak self] data, error in
                guard let self, let data = data else { return }
                self.gyroX = data.rotationRate.x
                self.gyroY = data.rotationRate.y
                self.gyroZ = data.rotationRate.z
            }
        }
        
        // Accelerometer
        if motionManager.isAccelerometerAvailable {
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self, let data = data else { return }
                self.accelX = data.acceleration.x
                self.accelY = data.acceleration.y
                self.accelZ = data.acceleration.z
            }
        }
        
        // Magnetometer
        if motionManager.isMagnetometerAvailable {
            motionManager.startMagnetometerUpdates(to: .main) { [weak self] data, error in
                guard let self, let data = data else { return }
                self.magnetometerX = data.magneticField.x
                self.magnetometerY = data.magneticField.y
                self.magnetometerZ = data.magneticField.z
            }
        }
    }
}
