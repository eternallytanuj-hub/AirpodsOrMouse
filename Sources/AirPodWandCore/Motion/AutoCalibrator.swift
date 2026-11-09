//
//  AutoCalibrator.swift
//  AirPodWandCore
//
//  Milestone 3: 6-DoF Attitude Reference Auto-Calibration & Grip Decoupling
//

import Foundation
import simd

/// Progressive calibration stages for handheld AirPod orientation locking.
public enum CalibrationPhase: String, Sendable, Equatable {
    case awaitingStillness
    case awaitingUpTilt
    case calibrated
}

/// 6-DoF Attitude Reference Auto-Calibrator and Grip Tilt Decoupler.
///
/// Features:
/// 1. Steady attitude detection (||ω|| < quiescenceThresholdRadS for requiredSteadyFrames).
/// 2. Quaternion reference mode (`q_ref* ⊗ ω_body ⊗ q_ref`) for arbitrary 3D test frames.
/// 3. Gravity-guided horizon mode (`useGravityHorizonCalibration == true`) anchoring yaw to
///    Earth gravity (`ω · g_down`) and locking exact screen-right/up pitch via optional guided
///    upward tilt or canonical upright projection—completely immune to arbitrary CoreMotion yaw.
/// 4. Rest recalibration and explicit triple-pinch recalibration support.
public struct AutoCalibrator: Sendable, Equatable {
    
    // MARK: - Configuration
    
    /// Maximum angular speed (rad/s) considered steady rest (default: 0.06 rad/s).
    public let quiescenceThresholdRadS: Double
    
    /// Consecutive steady frames required to capture calibration (default: 30 frames = 300 ms at 100 Hz).
    public let requiredSteadyFrames: Int
    
    /// Stationary rest duration (seconds) before triggering automatic recalibration (default: 3.0 s).
    public let restRecalibrationDurationSec: TimeInterval
    
    /// Enables Earth-gravity horizon leveling & guided handheld screen-basis alignment.
    public let useGravityHorizonCalibration: Bool
    
    /// Requires an upward wrist/AirPod tilt after stillness to lock screen-right axis for any grip.
    public let requireUpTiltGesture: Bool
    
    // MARK: - State Properties
    
    /// Current calibration phase.
    public private(set) var calibrationPhase: CalibrationPhase = .awaitingStillness
    
    /// Indicates whether calibration has completed and cursor output is active.
    public private(set) var isCalibrated: Bool = false
    
    /// Captured reference quaternion representing wand orientation at steady rest (quaternion mode).
    public private(set) var referenceQuaternion: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    
    /// Calibrated orthonormal screen basis in body coordinates (gravity-horizon mode).
    public private(set) var screenRightAxis: simd_double3 = simd_double3(1, 0, 0)
    public private(set) var screenForwardAxis: simd_double3 = simd_double3(0, 1, 0)
    public private(set) var screenUpAxis: simd_double3 = simd_double3(0, 0, 1)
    
    /// Number of consecutive frames meeting the steady quiescence threshold.
    public private(set) var quiescenceCount: Int = 0
    
    /// Accumulated duration of continuous stationary rest.
    public private(set) var stationaryDuration: TimeInterval = 0.0
    
    /// Flag indicating the device has rested >= 3.0 s and requires a refreshed reference attitude (quaternion mode).
    public private(set) var needsRecalibration: Bool = false
    
    /// Tracks whether motion has occurred following a prolonged rest period.
    public private(set) var hasMovedSinceRest: Bool = false
    
    /// True during the brief settle mute right after guided tilt completes.
    public var isInPostCalibrationSettle: Bool {
        postCalibrationSettleRemaining > 0.0
    }
    
    /// Monotonic timestamp of the previous processed frame.
    private var lastTimestamp: TimeInterval?
    private var gravityAccumulator: simd_double3 = .zero
    private var upTiltAccumulator: simd_double3 = .zero
    private var postCalibrationSettleRemaining: TimeInterval = 0.0
    
    // MARK: - Initialization
    
    public init(
        quiescenceThresholdRadS: Double = 0.06,
        requiredSteadyFrames: Int = 30,
        restRecalibrationDurationSec: TimeInterval = 3.0,
        useGravityHorizonCalibration: Bool = false,
        requireUpTiltGesture: Bool = false
    ) {
        self.quiescenceThresholdRadS = quiescenceThresholdRadS
        self.requiredSteadyFrames = max(1, requiredSteadyFrames)
        self.restRecalibrationDurationSec = restRecalibrationDurationSec
        self.useGravityHorizonCalibration = useGravityHorizonCalibration
        self.requireUpTiltGesture = requireUpTiltGesture
    }
    
    public init(config: EngineConfig) {
        self.init(
            quiescenceThresholdRadS: config.quiescenceThresholdRadS,
            requiredSteadyFrames: config.useGravityHorizonCalibration ? 25 : 30,
            restRecalibrationDurationSec: 3.0,
            useGravityHorizonCalibration: config.useGravityHorizonCalibration,
            requireUpTiltGesture: config.requireUpTiltGestureCalibration
        )
    }
    
    // MARK: - Primary Processing Pipeline
    
    /// Updates the calibration state and returns decoupled angular velocity.
    ///
    /// - Parameter frame: The incoming raw 6-DoF `MotionFrame`.
    /// - Returns: Decoupled angular velocity in user/screen pointing frame (x: pitchUp, y: yawRight, z: rollCW).
    public mutating func process(frame: MotionFrame) -> simd_double3 {
        let dt = advanceTimestamp(from: frame.timestamp)
        if useGravityHorizonCalibration {
            return processGravityHorizon(frame: frame, dt: dt)
        } else {
            updateQuaternionMode(frame: frame, dt: dt)
            return decouple(frame.rotationRate)
        }
    }
    
    /// Updates internal calibration and quiescence states from a motion frame.
    public mutating func update(frame: MotionFrame) {
        let dt = advanceTimestamp(from: frame.timestamp)
        if useGravityHorizonCalibration {
            _ = processGravityHorizon(frame: frame, dt: dt)
        } else {
            updateQuaternionMode(frame: frame, dt: dt)
        }
    }
    
    private mutating func advanceTimestamp(from timestamp: TimeInterval) -> TimeInterval {
        guard timestamp.isFinite else { return 0.010 }
        let dt: TimeInterval
        if let lastT = lastTimestamp, timestamp > lastT {
            dt = min(max(timestamp - lastT, 0.001), 0.100)
        } else {
            dt = 0.010
        }
        lastTimestamp = timestamp
        return dt
    }
    
    // MARK: - Quaternion Reference Mode (Backward-Compatible Core DSP)
    
    private mutating func updateQuaternionMode(frame: MotionFrame, dt: TimeInterval) {
        guard frame.timestamp.isFinite else {
            quiescenceCount = 0
            stationaryDuration = 0.0
            return
        }
        
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
                    calibrationPhase = .calibrated
                    needsRecalibration = false
                    hasMovedSinceRest = false
                }
            } else if needsRecalibration && hasMovedSinceRest {
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
    
    // MARK: - Gravity-Guided Horizon Mode (Handheld Single-AirPod)
    
    private mutating func processGravityHorizon(frame: MotionFrame, dt: TimeInterval) -> simd_double3 {
        guard frame.timestamp.isFinite else { return .zero }
        let rates = frame.rotationRate
        guard rates.x.isFinite, rates.y.isFinite, rates.z.isFinite else { return .zero }
        let speed = simd_length(rates)
        guard speed.isFinite else { return .zero }
        
        switch calibrationPhase {
        case .awaitingStillness:
            if speed < quiescenceThresholdRadS {
                quiescenceCount += 1
                stationaryDuration += dt
                if let gHat = normalizedDownGravity(from: frame) {
                    gravityAccumulator += gHat
                }
                if quiescenceCount >= requiredSteadyFrames {
                    let avgDown = simd_length(gravityAccumulator) > 1e-6
                        ? simd_normalize(gravityAccumulator)
                        : (normalizedDownGravity(from: frame) ?? simd_double3(0, 0, -1))
                    screenUpAxis = -avgDown
                    gravityAccumulator = .zero
                    upTiltAccumulator = .zero
                    needsRecalibration = false
                    hasMovedSinceRest = false
                    
                    if requireUpTiltGesture {
                        calibrationPhase = .awaitingUpTilt
                        isCalibrated = false
                    } else {
                        setCanonicalScreenBasis(upAxis: screenUpAxis)
                        calibrationPhase = .calibrated
                        isCalibrated = true
                        postCalibrationSettleRemaining = 0.0
                    }
                }
            } else {
                quiescenceCount = 0
                stationaryDuration = 0.0
                gravityAccumulator = .zero
            }
            return .zero
            
        case .awaitingUpTilt:
            let up = currentUpAxis(from: frame) ?? screenUpAxis
            // Project body rotation perpendicular to Earth vertical (pure pitch/tilt components)
            let omegaPerp = rates - up * simd_dot(rates, up)
            let perpSpeed = simd_length(omegaPerp)
            
            if perpSpeed >= 0.25 {
                if simd_length(upTiltAccumulator) > 0.02 && simd_dot(omegaPerp, upTiltAccumulator) < 0.0 {
                    // Direction reversed before locking; track new upward stroke cleanly
                    upTiltAccumulator = omegaPerp * dt
                } else {
                    upTiltAccumulator += omegaPerp * dt
                }
                
                // ~8 degrees (0.14 rad) deliberate tilt locks Screen-Right pitch axis directly
                if simd_length(upTiltAccumulator) >= 0.14 {
                    let rightCandidate = upTiltAccumulator - up * simd_dot(upTiltAccumulator, up)
                    if simd_length(rightCandidate) > 1e-6 {
                        screenUpAxis = up
                        screenRightAxis = simd_normalize(rightCandidate)
                        screenForwardAxis = simd_normalize(simd_cross(screenUpAxis, screenRightAxis))
                        calibrationPhase = .calibrated
                        isCalibrated = true
                        postCalibrationSettleRemaining = 0.18
                        quiescenceCount = 0
                        stationaryDuration = 0.0
                        upTiltAccumulator = .zero
                    }
                }
            } else if perpSpeed < 0.15 {
                // Decay micro-tremor so slow hand tremor never accidentally completes Stage 2
                upTiltAccumulator *= 0.85
            }
            return .zero
            
        case .calibrated:
            if postCalibrationSettleRemaining > 0.0 {
                postCalibrationSettleRemaining = max(0.0, postCalibrationSettleRemaining - dt)
                return .zero
            }
            
            // Silently refine horizon vertical vector if resting cleanly (without pausing cursor)
            if speed < quiescenceThresholdRadS {
                if let up = currentUpAxis(from: frame) {
                    let rCandidate = screenRightAxis - up * simd_dot(screenRightAxis, up)
                    if simd_length(rCandidate) > 0.25 {
                        screenUpAxis = up
                        screenRightAxis = simd_normalize(rCandidate)
                        screenForwardAxis = simd_normalize(simd_cross(screenUpAxis, screenRightAxis))
                    }
                }
            }
            
            return decoupleGravityFrame(rates: rates, frame: frame)
        }
    }
    
    // MARK: - Decoupling Transformation
    
    /// Decouples a 3D angular velocity vector from device body frame to user pointing frame.
    @inlinable
    public func decouple(_ rotationRate: simd_double3) -> simd_double3 {
        guard rotationRate.x.isFinite, rotationRate.y.isFinite, rotationRate.z.isFinite else {
            return .zero
        }
        if useGravityHorizonCalibration {
            guard calibrationPhase == .calibrated, !isInPostCalibrationSettle else {
                return .zero
            }
            let pitchUp = simd_dot(rotationRate, screenRightAxis)
            let yawRight = -simd_dot(rotationRate, screenUpAxis)
            let rollCW = simd_dot(rotationRate, screenForwardAxis)
            let result = simd_double3(pitchUp, yawRight, rollCW)
            return (result.x.isFinite && result.y.isFinite && result.z.isFinite) ? result : .zero
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
    
    private func decoupleGravityFrame(rates: simd_double3, frame: MotionFrame) -> simd_double3 {
        let liveUp = currentUpAxis(from: frame) ?? screenUpAxis
        let rProj = screenRightAxis - liveUp * simd_dot(screenRightAxis, liveUp)
        let (rAxis, fAxis, uAxis): (simd_double3, simd_double3, simd_double3)
        if simd_length(rProj) > 0.25 {
            let rNorm = simd_normalize(rProj)
            let fNorm = simd_normalize(simd_cross(liveUp, rNorm))
            (rAxis, fAxis, uAxis) = (rNorm, fNorm, liveUp)
        } else {
            (rAxis, fAxis, uAxis) = (screenRightAxis, screenForwardAxis, screenUpAxis)
        }
        
        // Right-handed dot projections:
        // - pitchUp: tilting beam toward +up rotates +around screenRight
        // - yawRight: turning beam toward +right rotates +around gravity (-up)
        // - rollCW: twisting clockwise looking forward rotates +around forward
        let pitchUp = simd_dot(rates, rAxis)
        let yawRight = -simd_dot(rates, uAxis)
        let rollCW = simd_dot(rates, fAxis)
        let result = simd_double3(pitchUp, yawRight, rollCW)
        return (result.x.isFinite && result.y.isFinite && result.z.isFinite) ? result : .zero
    }
    
    // MARK: - Calibration Control APIs
    
    /// Directly injects a known reference quaternion for deterministic test isolation or manual override.
    public mutating func forceCalibrate(_ quat: simd_quatd) {
        captureReference(from: quat)
        isCalibrated = true
        calibrationPhase = .calibrated
        quiescenceCount = requiredSteadyFrames
        needsRecalibration = false
        hasMovedSinceRest = false
        stationaryDuration = 0.0
        postCalibrationSettleRemaining = 0.0
        if useGravityHorizonCalibration {
            let up = simd_normalize(simd_act(simd_conjugate(referenceQuaternion), simd_double3(0, 0, 1)))
            screenUpAxis = (up.x.isFinite && up.y.isFinite && up.z.isFinite) ? up : simd_double3(0, 0, 1)
            setCanonicalScreenBasis(upAxis: screenUpAxis)
        }
    }
    
    /// Injects an explicit orthonormal screen basis directly (right, forward, up) in body coordinates.
    public mutating func forceCalibrateBasis(right: simd_double3, forward: simd_double3, up: simd_double3) {
        guard simd_length(right) > 1e-6, simd_length(up) > 1e-6 else { return }
        let u = simd_normalize(up)
        let rRaw = right - u * simd_dot(right, u)
        guard simd_length(rRaw) > 1e-6 else { return }
        let r = simd_normalize(rRaw)
        let f = simd_normalize(simd_cross(u, r))
        screenUpAxis = u
        screenRightAxis = r
        screenForwardAxis = f
        isCalibrated = true
        calibrationPhase = .calibrated
        quiescenceCount = requiredSteadyFrames
        needsRecalibration = false
        hasMovedSinceRest = false
        postCalibrationSettleRemaining = 0.0
    }
    
    /// Flags the calibrator to capture a refreshed reference attitude.
    public mutating func requestRecalibration() {
        if useGravityHorizonCalibration {
            isCalibrated = false
            calibrationPhase = .awaitingStillness
            quiescenceCount = 0
            stationaryDuration = 0.0
            gravityAccumulator = .zero
            upTiltAccumulator = .zero
            postCalibrationSettleRemaining = 0.0
        }
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
        calibrationPhase = .awaitingStillness
        referenceQuaternion = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        screenRightAxis = simd_double3(1, 0, 0)
        screenForwardAxis = simd_double3(0, 1, 0)
        screenUpAxis = simd_double3(0, 0, 1)
        quiescenceCount = 0
        stationaryDuration = 0.0
        needsRecalibration = false
        hasMovedSinceRest = false
        lastTimestamp = nil
        gravityAccumulator = .zero
        upTiltAccumulator = .zero
        postCalibrationSettleRemaining = 0.0
    }
    
    // MARK: - Private Helpers
    
    private mutating func setCanonicalScreenBasis(upAxis: simd_double3) {
        let u = simd_length(upAxis) > 1e-6 ? simd_normalize(upAxis) : simd_double3(0, 0, 1)
        // Canonical Apple headphone body forward is +Y; fallback +X or +Z if nearly parallel to up
        let candidateForward: simd_double3
        if abs(simd_dot(u, simd_double3(0, 1, 0))) < 0.90 {
            candidateForward = simd_double3(0, 1, 0)
        } else if abs(simd_dot(u, simd_double3(1, 0, 0))) < 0.90 {
            candidateForward = simd_double3(1, 0, 0)
        } else {
            candidateForward = simd_double3(0, 0, 1)
        }
        let r = simd_normalize(simd_cross(candidateForward, u))
        let f = simd_normalize(simd_cross(u, r))
        screenUpAxis = u
        screenRightAxis = r
        screenForwardAxis = f
    }
    
    private func normalizedDownGravity(from frame: MotionFrame) -> simd_double3? {
        if let g = frame.gravity, g.x.isFinite, g.y.isFinite, g.z.isFinite {
            let len = simd_length(g)
            if len.isFinite && len > 0.1 {
                return g / len
            }
        }
        let vec = frame.attitudeQuaternion.vector
        guard vec.x.isFinite, vec.y.isFinite, vec.z.isFinite, vec.w.isFinite else { return nil }
        let qNorm = simd_length(frame.attitudeQuaternion)
        guard qNorm.isFinite && qNorm > 1e-6 else { return nil }
        // CoreMotion CMAttitude.quaternion maps body -> world: v_world = simd_act(q, v_body).
        // Therefore world down (0, 0, -1) expressed in body coordinates is simd_act(simd_conjugate(q), (0, 0, -1)).
        let rotated = simd_act(simd_conjugate(simd_normalize(frame.attitudeQuaternion)), simd_double3(0, 0, -1))
        let len = simd_length(rotated)
        return (len.isFinite && len > 0.1) ? (rotated / len) : nil
    }
    
    private func currentUpAxis(from frame: MotionFrame) -> simd_double3? {
        guard let down = normalizedDownGravity(from: frame) else { return nil }
        return -down
    }
    
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
