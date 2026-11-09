//
//  SigmoidBallistics.swift
//  AirPodWandCore
//
//  Milestone 3: 5-Parameter Generalized Logistic Velocity Ballistics
//

import Foundation

/// 5-parameter generalized logistic gain curve mapping angular velocity (rad/s) to macOS screen pixel deltas.
///
/// Gain formula:
/// G(v) = G_min + (G_max - G_min) / (1 + exp(-k * (v - v_mid)))
///
/// Coordinate Projection:
/// - macOS screen origin is top-left (x: right, y: down).
/// - dx = ω_yaw * G(||ω||) * Δt (positive yaw right -> positive dx).
/// - dy = -ω_pitch * G(||ω||) * Δt (positive pitch up -> negative dy).
/// - Deadzone: ||ω|| < v_dead -> dx = 0, dy = 0.
public struct SigmoidBallistics: Sendable, Equatable {
    
    // MARK: - Parameters
    
    /// Minimum ballistic gain (screen px per radian) at slow precision speeds (default: 400.0).
    public let minGain: Double
    
    /// Maximum ballistic gain (screen px per radian) during fast flicks (default: 2800.0).
    public let maxGain: Double
    
    /// Inflection point velocity (rad/s) where sigmoid gain transitions from precision to flick (default: 0.70).
    public let midVelocity: Double
    
    /// Slope parameter controlling sigmoid steepness (k, default: 5.0).
    public let slope: Double
    
    /// Angular velocity deadband (rad/s) below which motion is clamped to zero (default: 0.015).
    public let deadband: Double
    
    // MARK: - Aliases for Project Invariant Naming
    
    public var gMin: Double { minGain }
    public var gMax: Double { maxGain }
    public var vMid: Double { midVelocity }
    public var k: Double { slope }
    public var vDead: Double { deadband }
    
    // MARK: - Initialization
    
    public init(
        minGain: Double = 400.0,
        maxGain: Double = 2800.0,
        midVelocity: Double = 0.70,
        slope: Double = 5.0,
        deadband: Double = 0.015
    ) {
        self.minGain = minGain
        self.maxGain = maxGain
        self.midVelocity = midVelocity
        self.slope = slope
        self.deadband = deadband
    }
    
    public init(
        gMin: Double,
        gMax: Double,
        vMid: Double,
        k: Double,
        deadband: Double
    ) {
        self.minGain = gMin
        self.maxGain = gMax
        self.midVelocity = vMid
        self.slope = k
        self.deadband = deadband
    }
    
    public init(config: EngineConfig) {
        self.minGain = config.ballisticsMinGain
        self.maxGain = config.ballisticsMaxGain
        self.midVelocity = config.ballisticsMidVelocity
        self.slope = config.ballisticsSlope
        self.deadband = config.ballisticsDeadband
    }
    
    // MARK: - Ballistics Gain Calculation
    
    /// Evaluates the sigmoid gain in px/rad for a given planar speed in rad/s.
    /// Clamps to 0.0 if speed is below deadband or non-finite.
    public func gain(forSpeed speed: Double) -> Double {
        guard speed.isFinite,
              minGain.isFinite, maxGain.isFinite,
              midVelocity.isFinite, slope.isFinite, deadband.isFinite,
              speed >= deadband else {
            return 0.0
        }
        let exponent = -slope * (speed - midVelocity)
        // Clamp exponent to prevent numerical overflow in exp()
        let clampedExponent = min(max(exponent, -60.0), 60.0)
        return minGain + (maxGain - minGain) / (1.0 + exp(clampedExponent))
    }
    
    // MARK: - Delta Computation
    
    /// Computes relative cursor pixel displacement given filtered angular rates and frame interval dt.
    ///
    /// - Parameters:
    ///   - pitchRate: Filtered pitch angular rate in rad/s (positive = upward tilt).
    ///   - yawRate: Filtered yaw angular rate in rad/s (positive = rightward turn).
    ///   - dt: Time step interval in seconds (default: 0.010 s for 100 Hz).
    ///   - timestamp: Monotonic timestamp for the delta.
    /// - Returns: `CursorDelta` with screen projection and deadband clamping.
    public func calculateDelta(
        pitchRate: Double,
        yawRate: Double,
        dt: Double = 0.010,
        timestamp: TimeInterval = 0
    ) -> CursorDelta {
        let safeTimestamp = timestamp.isFinite ? timestamp : 0.0
        guard pitchRate.isFinite, yawRate.isFinite, dt.isFinite, dt > 0.0 else {
            return CursorDelta.zero
        }
        
        let clampedDt = min(dt, 0.050)
        let speed = hypot(pitchRate, yawRate)
        
        guard speed.isFinite, speed >= deadband else {
            return CursorDelta(dx: 0.0, dy: 0.0, isLocked: false, timestamp: safeTimestamp)
        }
        
        let g = gain(forSpeed: speed)
        
        // Coordinate projection:
        // Screen X is driven by yaw (turning right increases X on screen)
        // Screen Y is driven by pitch (tilting up decreases Y in macOS top-left coordinate system)
        let dx = yawRate * g * clampedDt
        let dy = -pitchRate * g * clampedDt
        guard dx.isFinite, dy.isFinite else {
            return CursorDelta(dx: 0.0, dy: 0.0, isLocked: false, timestamp: safeTimestamp)
        }
        
        return CursorDelta(dx: dx, dy: dy, isLocked: false, timestamp: safeTimestamp)
    }
}
