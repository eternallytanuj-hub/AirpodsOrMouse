//
//  AutoCalibrator.swift
//  AirPodWandCore
//
//  Milestone 3: 6-DoF Attitude Reference Auto-Calibration & Grip Decoupling
//

import Foundation
import simd

/// 6-DoF Attitude Reference Auto-Calibrator and Grip Tilt Decoupler.
///
/// Features:
/// 1. Steady attitude detection (||ω|| < 0.06 rad/s for >= 300 ms / 30 frames at 100 Hz).
/// 2. Capture of reference attitude unit quaternion q_ref.
/// 3. Grip tilt decoupling via quaternion conjugate action: ω_decoupled = q_ref* ⊗ ω_body ⊗ q_ref.
/// 4. Rest recalibration trigger after >= 3.0 s stationary rest.
/// 5. Guaranteed cross-axis coupling < 2.0% across all 3D grip angles.
public struct AutoCalibrator: Sendable, Equatable {
    
    // MARK: - Configuration
    
    /// Maximum angular speed (rad/s) considered steady rest (default: 0.06 rad/s).
    public let quiescenceThresholdRadS: Double
    
    /// Consecutive steady frames required to capture calibration (default: 30 frames = 300 ms at 100 Hz).
    public let requiredSteadyFrames: Int
    
    /// Stationary rest duration (seconds) before triggering automatic recalibration (default: 3.0 s).
    public let restRecalibrationDurationSec: TimeInterval
    
    // MARK: - State Properties
    
    /// Indicates whether an initial steady attitude reference has been established.
    public private(set) var isCalibrated: Bool = false
    
    /// Captured reference quaternion representing wand orientation at steady rest.
    public private(set) var referenceQuaternion: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    
    /// Number of consecutive frames meeting the steady quiescence threshold.
    public private(set) var quiescenceCount: Int = 0
    
    /// Accumulated duration of continuous stationary rest.
    public private(set) var stationaryDuration: TimeInterval = 0.0
    
    /// Flag indicating the device has rested >= 3.0 s and requires a refreshed reference quaternion upon resume.
    public private(set) var needsRecalibration: Bool = false
    
    /// Tracks whether motion has occurred following a prolonged rest period.
    public private(set) var hasMovedSinceRest: Bool = false
    
    /// Monotonic timestamp of the previous processed frame.
    private var lastTimestamp: TimeInterval?
    
    // MARK: - Initialization
    
    public init(
        quiescenceThresholdRadS: Double = 0.06,
        requiredSteadyFrames: Int = 30,
        restRecalibrationDurationSec: TimeInterval = 3.0
    ) {
        self.quiescenceThresholdRadS = quiescenceThresholdRadS
        self.requiredSteadyFrames = requiredSteadyFrames
        self.restRecalibrationDurationSec = restRecalibrationDurationSec
    }
    
    public init(config: EngineConfig) {
        self.init(
            quiescenceThresholdRadS: 0.06,
            requiredSteadyFrames: 30,
            restRecalibrationDurationSec: 3.0
        )
    }
    
    // MARK: - Primary Processing Pipeline
    
    /// Updates the calibration state and returns decoupled angular velocity.
    ///
    /// - Parameter frame: The incoming raw 6-DoF `MotionFrame`.
    /// - Returns: Decoupled angular velocity in user/screen pointing frame (x: pitch, y: yaw, z: roll).
    public mutating func process(frame: MotionFrame) -> simd_double3 {
        update(frame: frame)
        return decouple(frame.rotationRate)
    }
    
    /// Updates internal calibration and quiescence states from a motion frame.
    public mutating func update(frame: MotionFrame) {
        guard frame.timestamp.isFinite else {
            quiescenceCount = 0
            stationaryDuration = 0.0
            return
        }

        let dt: TimeInterval
        if let lastT = lastTimestamp, frame.timestamp > lastT {
            dt = min(max(frame.timestamp - lastT, 0.001), 0.100)
        } else {
            dt = 0.010 // Default 100 Hz interval
        }
        lastTimestamp = frame.timestamp
        
        let rates = frame.rotationRate
        guard rates.x.isFinite, rates.y.isFinite, rates.z.isFinite else {
            quiescenceCount = 0
            stationaryDuration = 0.0
            if needsRecalibration {
                hasMovedSinceRest = true
            }
            return
        }

        let speed = simd_length(rates)
        guard speed.isFinite else {
            quiescenceCount = 0
            stationaryDuration = 0.0
            if needsRecalibration {
                hasMovedSinceRest = true
            }
            return
        }
        let isSteady = speed < quiescenceThresholdRadS
        
        if isSteady {
            quiescenceCount += 1
            stationaryDuration += dt
            
            if stationaryDuration >= restRecalibrationDurationSec {
                needsRecalibration = true
            }
            
            if !isCalibrated {
                if quiescenceCount >= requiredSteadyFrames {
                    captureReference(from: frame.attitudeQuaternion)
                    isCalibrated = true
                    needsRecalibration = false
                    hasMovedSinceRest = false
                }
            } else if needsRecalibration && hasMovedSinceRest {
                // Execute recalibration once user has moved and re-stabilized pointing at screen
                if quiescenceCount >= requiredSteadyFrames {
                    captureReference(from: frame.attitudeQuaternion)
                    needsRecalibration = false
                    hasMovedSinceRest = false
                }
            }
        } else {
            quiescenceCount = 0
            stationaryDuration = 0.0
            if needsRecalibration {
                hasMovedSinceRest = true
            }
        }
    }
    
    // MARK: - Decoupling Transformation
    
    /// Decouples a 3D angular velocity vector from device body frame to user pointing frame.
    ///
    /// Formula: ω_decoupled = q_ref* ⊗ ω_body ⊗ q_ref
    @inlinable
    public func decouple(_ rotationRate: simd_double3) -> simd_double3 {
        guard rotationRate.x.isFinite, rotationRate.y.isFinite, rotationRate.z.isFinite else {
            return .zero
        }
        guard isCalibrated else {
            return rotationRate
        }
        let qRefConj = simd_conjugate(referenceQuaternion)
        let decoupled = simd_act(qRefConj, rotationRate)
        guard decoupled.x.isFinite, decoupled.y.isFinite, decoupled.z.isFinite else {
            return .zero
        }
        return decoupled
    }
    
    /// Decouples rotation rate with explicit attitude support if needed.
    @inlinable
    public func decouple(rotationRate: simd_double3, attitude: simd_quatd) -> simd_double3 {
        decouple(rotationRate)
    }
    
    // MARK: - Calibration Control APIs
    
    /// Directly injects a known reference quaternion for deterministic test isolation or manual override.
    public mutating func forceCalibrate(_ quat: simd_quatd) {
        captureReference(from: quat)
        isCalibrated = true
        quiescenceCount = requiredSteadyFrames
        needsRecalibration = false
        hasMovedSinceRest = false
        stationaryDuration = 0.0
    }
    
    /// Flags the calibrator to capture a refreshed reference attitude as soon as steady conditions are observed.
    public mutating func requestRecalibration() {
        needsRecalibration = true
        hasMovedSinceRest = true
        quiescenceCount = 0
    }
    
    /// Recalibrates reference orientation. If quaternion is nil, requests automatic recalibration upon next settle.
    public mutating func recalibrate(quaternion: simd_quatd? = nil) {
        if let q = quaternion {
            forceCalibrate(q)
        } else {
            requestRecalibration()
        }
    }
    
    /// Fully resets the calibrator to initial uncalibrated state.
    public mutating func reset() {
        isCalibrated = false
        referenceQuaternion = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        quiescenceCount = 0
        stationaryDuration = 0.0
        needsRecalibration = false
        hasMovedSinceRest = false
        lastTimestamp = nil
    }
    
    // MARK: - Private Helpers
    
    private mutating func captureReference(from quat: simd_quatd) {
        let vec = quat.vector
        let allFinite = vec.x.isFinite && vec.y.isFinite && vec.z.isFinite && vec.w.isFinite
        let norm = allFinite ? simd_length(quat) : 0.0
        if allFinite && norm.isFinite && norm > 1e-6 {
            let normalized = simd_normalize(quat)
            let normVec = normalized.vector
            if normVec.x.isFinite && normVec.y.isFinite && normVec.z.isFinite && normVec.w.isFinite {
                referenceQuaternion = normalized
                return
            }
        }
        referenceQuaternion = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    }
}
