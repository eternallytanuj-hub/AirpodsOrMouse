import Foundation
import simd

/// An immutable, Sendable 6-DoF inertial motion frame representing an AirPod sensor snapshot.
public struct MotionFrame: Sendable, Equatable {
    /// Sensor acquisition timestamp in seconds (monotonic TimeInterval).
    public let timestamp: TimeInterval
    
    /// Attitude orientation represented as a unit quaternion (ix, iy, iz, r) in Double precision.
    public let attitudeQuaternion: simd_quatd
    
    /// Angular velocity in radians per second:
    /// - x: pitch rate (nodding down/up)
    /// - y: yaw rate (turning right/left)
    /// - z: roll rate (axial rotation along wand stem)
    public let rotationRate: simd_double3
    
    /// User linear acceleration in gravitational units (g, ~9.81 m/s^2), excluding gravity.
    public let userAcceleration: simd_double3
    
    /// Filtered gravity vector in device body coordinates when provided by CoreMotion (pointing Earth-down).
    public let gravity: simd_double3?
    
    public init(
        timestamp: TimeInterval,
        attitudeQuaternion: simd_quatd,
        rotationRate: simd_double3,
        userAcceleration: simd_double3 = simd_double3(0, 0, 0),
        gravity: simd_double3? = nil
    ) {
        self.timestamp = timestamp
        self.attitudeQuaternion = attitudeQuaternion
        self.rotationRate = rotationRate
        self.userAcceleration = userAcceleration
        self.gravity = gravity
    }
}

extension MotionFrame {
    /// Convenience pitch angular rate in radians per second.
    @inlinable public var pitchRate: Double { rotationRate.x }
    
    /// Convenience yaw angular rate in radians per second.
    @inlinable public var yawRate: Double { rotationRate.y }
    
    /// Convenience roll angular rate in radians per second.
    @inlinable public var rollRate: Double { rotationRate.z }
    
    /// Creates an identity motion frame at rest with no rotation or acceleration.
    public static func identity(timestamp: TimeInterval = 0) -> MotionFrame {
        MotionFrame(
            timestamp: timestamp,
            attitudeQuaternion: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            rotationRate: simd_double3(0, 0, 0),
            userAcceleration: simd_double3(0, 0, 0)
        )
    }
}
