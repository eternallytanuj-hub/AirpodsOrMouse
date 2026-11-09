import Foundation

/// Configuration parameters governing the 6-DoF Motion DSP, 1€ filter, ballistics, and gesture click engines.
public struct EngineConfig: Sendable, Equatable {
    /// IMU sensor sample rate in Hz (default 100 Hz).
    public var sampleRateHz: Double
    
    // MARK: - 1€ Filter Parameters
    
    /// Minimum cutoff frequency in Hz for low velocities (suppresses hand tremor).
    public var oneEuroMinCutoff: Double
    
    /// Speed coefficient scaling cutoff frequency with velocity.
    public var oneEuroBeta: Double
    
    /// Cutoff frequency in Hz for derivative smoothing.
    public var oneEuroDercutoff: Double
    
    // MARK: - Ballistics Parameters
    
    /// Minimum ballistic gain (screen px per radian) at slow precision speeds.
    public var ballisticsMinGain: Double
    
    /// Maximum ballistic gain (screen px per radian) during fast flicks.
    public var ballisticsMaxGain: Double
    
    /// Inflection point velocity (rad/s) where sigmoid gain transitions from precision to flick.
    public var ballisticsMidVelocity: Double
    
    /// Slope parameter controlling sigmoid steepness.
    public var ballisticsSlope: Double
    
    /// Angular velocity deadband (rad/s) below which motion is ignored.
    public var ballisticsDeadband: Double
    
    // MARK: - Roll-Twist Click Parameters
    
    /// Longitudinal roll angular rate threshold in rad/s to trigger an axial roll-twist click.
    public var rollTwistThresholdRadS: Double
    
    /// Maximum allowable planar (pitch/yaw) angular speed in rad/s during a valid twist gesture.
    public var rollTwistMaxPlanarRadS: Double
    
    /// Duration in seconds to lock cursor displacement during and immediately following a twist.
    public var rollTwistLockoutDuration: TimeInterval
    
    /// Refractory debounce duration in seconds before subsequent twist gestures can trigger.
    public var rollTwistDebounceDuration: TimeInterval
    
    // MARK: - Hover-Dwell Click Parameters
    
    /// Maximum drift radius in screen points defining the dwell anchor circle.
    public var hoverDwellRadiusPx: Double
    
    /// Stationary dwell time in seconds required inside the anchor radius to trigger a click.
    public var hoverDwellDurationSec: TimeInterval
    
    /// Minimum preceding travel in screen points required before the dwell state machine arms.
    public var hoverDwellMinTravelPx: Double
    
    /// Refractory cooldown duration in seconds following a dwell click.
    public var hoverDwellCooldownSec: TimeInterval
    
    public init(
        sampleRateHz: Double = 100.0,
        oneEuroMinCutoff: Double = 0.8,
        oneEuroBeta: Double = 0.40,
        oneEuroDercutoff: Double = 1.0,
        ballisticsMinGain: Double = 400.0,
        ballisticsMaxGain: Double = 2800.0,
        ballisticsMidVelocity: Double = 0.70,
        ballisticsSlope: Double = 5.0,
        ballisticsDeadband: Double = 0.015,
        rollTwistThresholdRadS: Double = 4.2,
        rollTwistMaxPlanarRadS: Double = 1.2,
        rollTwistLockoutDuration: TimeInterval = 0.18,
        rollTwistDebounceDuration: TimeInterval = 0.40,
        hoverDwellRadiusPx: Double = 4.0,
        hoverDwellDurationSec: TimeInterval = 0.450,
        hoverDwellMinTravelPx: Double = 25.0,
        hoverDwellCooldownSec: TimeInterval = 0.500
    ) {
        self.sampleRateHz = sampleRateHz
        self.oneEuroMinCutoff = oneEuroMinCutoff
        self.oneEuroBeta = oneEuroBeta
        self.oneEuroDercutoff = oneEuroDercutoff
        self.ballisticsMinGain = ballisticsMinGain
        self.ballisticsMaxGain = ballisticsMaxGain
        self.ballisticsMidVelocity = ballisticsMidVelocity
        self.ballisticsSlope = ballisticsSlope
        self.ballisticsDeadband = ballisticsDeadband
        self.rollTwistThresholdRadS = rollTwistThresholdRadS
        self.rollTwistMaxPlanarRadS = rollTwistMaxPlanarRadS
        self.rollTwistLockoutDuration = rollTwistLockoutDuration
        self.rollTwistDebounceDuration = rollTwistDebounceDuration
        self.hoverDwellRadiusPx = hoverDwellRadiusPx
        self.hoverDwellDurationSec = hoverDwellDurationSec
        self.hoverDwellMinTravelPx = hoverDwellMinTravelPx
        self.hoverDwellCooldownSec = hoverDwellCooldownSec
    }
}
