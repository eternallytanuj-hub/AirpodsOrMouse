//
//  GestureClickEngine.swift
//  AirPodWandCore
//
//  Milestone 3: Axial Roll-Twist Click Engine & Hover-Dwell Finite State Machine
//

import Foundation
import CoreGraphics

/// Evaluates axial roll-twist gestures along the wand stem and enforces predictive cursor delta locking.
///
/// Specification:
/// - Axial threshold: |ω_roll| > 4.2 rad/s
/// - Planar guard: v_planar = sqrt(ω_pitch^2 + ω_yaw^2) < 1.2 rad/s
/// - Clockwise (ω_roll > +4.2) -> .leftClick(source: "roll_twist_cw")
/// - Counter-Clockwise (ω_roll < -4.2) -> .rightClick(source: "roll_twist_ccw")
/// - Predictive lock: engages at |ω_roll| >= 2.0 rad/s, freezing cursor deltas (0.00 px wander) for 180 ms.
/// - Debounce: 400 ms refractory cooldown.
public struct RollTwistClickDetector: Sendable, Equatable {
    
    // MARK: - Parameters
    
    public let thresholdRadS: Double
    public let maxPlanarRadS: Double
    public let lockoutDuration: TimeInterval
    public let debounceDuration: TimeInterval
    public let onsetLockThresholdRadS: Double
    
    // MARK: - State Memory
    
    public private(set) var isLocked: Bool = false
    public private(set) var lockRemainingSec: TimeInterval = 0.0
    public private(set) var lastClickTimestamp: TimeInterval = -100.0
    
    // MARK: - Initialization
    
    public init(
        thresholdRadS: Double = 4.2,
        maxPlanarRadS: Double = 1.2,
        lockoutDuration: TimeInterval = 0.180,
        debounceDuration: TimeInterval = 0.400,
        onsetLockThresholdRadS: Double = 2.0
    ) {
        self.thresholdRadS = thresholdRadS
        self.maxPlanarRadS = maxPlanarRadS
        self.lockoutDuration = lockoutDuration
        self.debounceDuration = debounceDuration
        self.onsetLockThresholdRadS = onsetLockThresholdRadS
    }
    
    public init(config: EngineConfig) {
        self.thresholdRadS = config.rollTwistThresholdRadS
        self.maxPlanarRadS = config.rollTwistMaxPlanarRadS
        self.lockoutDuration = config.rollTwistLockoutDuration
        self.debounceDuration = config.rollTwistDebounceDuration
        self.onsetLockThresholdRadS = 2.0
    }
    
    // MARK: - Processing Pipeline
    
    /// Evaluates roll rate, planar speed, and timing to determine if a twist click should be emitted,
    /// while managing predictive cursor delta locking.
    public mutating func process(
        pitchRate: Double,
        yawRate: Double,
        rollRate: Double,
        timestamp: TimeInterval,
        dt: TimeInterval = 0.010
    ) -> (click: ClickType?, isLocked: Bool) {
        let validDt = (dt.isFinite && dt > 0.0) ? dt : 0.0

        // Step 1: Decrement active lockout duration
        if isLocked && validDt > 0.0 {
            lockRemainingSec -= validDt
            if lockRemainingSec <= 1e-6 {
                isLocked = false
                lockRemainingSec = 0.0
            }
        }

        // Reject non-finite telemetry inputs before evaluating roll onset or click triggers
        guard pitchRate.isFinite, yawRate.isFinite, rollRate.isFinite, timestamp.isFinite else {
            return (nil, isLocked)
        }
        
        // Step 2: Predictive onset lock at 2.0 rad/s
        if abs(rollRate) >= onsetLockThresholdRadS {
            isLocked = true
            lockRemainingSec = max(lockRemainingSec, lockoutDuration)
        }
        
        // Step 3: Trigger criteria evaluation
        var emittedClick: ClickType? = nil
        let planarSpeed = hypot(pitchRate, yawRate)
        
        if abs(rollRate) > thresholdRadS && planarSpeed < maxPlanarRadS {
            let elapsed = timestamp - lastClickTimestamp
            if elapsed >= debounceDuration {
                lastClickTimestamp = timestamp
                isLocked = true
                lockRemainingSec = lockoutDuration
                
                if rollRate > thresholdRadS {
                    emittedClick = .leftClick(source: "roll_twist_cw")
                } else if rollRate < -thresholdRadS {
                    emittedClick = .rightClick(source: "roll_twist_ccw")
                }
            }
        }
        
        return (emittedClick, isLocked)
    }
    
    /// Resets all internal detector state.
    public mutating func reset() {
        isLocked = false
        lockRemainingSec = 0.0
        lastClickTimestamp = -100.0
    }
}

/// 4-State Hover-Dwell Finite State Machine.
///
/// States:
/// - IDLE: Accumulates travel; requires >= 25 px cumulative approach to prime.
/// - ARMED: Once primed and cursor slows down, latches anchor position.
/// - DWELLING: Holds inside 4 px radius for 450 ms -> triggers .leftClick(source: "hover_dwell").
/// - COOLDOWN: Refractory cooldown for 500 ms with single-shot disarm.
public struct HoverDwellClickDetector: Sendable, Equatable {
    
    public enum State: Sendable, Equatable {
        case idle
        case armed
        case dwelling(anchor: CGPoint, dwellTime: TimeInterval)
        case cooldown(remainingSec: TimeInterval)
    }
    
    // MARK: - Parameters
    
    public let radiusPx: Double
    public let durationSec: TimeInterval
    public let minTravelPx: Double
    public let cooldownSec: TimeInterval
    public let stationaryThresholdPx: Double
    
    // MARK: - State Memory
    
    public private(set) var state: State = .idle
    public private(set) var accumulatedTravel: Double = 0.0
    public private(set) var virtualCursorPosition: CGPoint
    
    // MARK: - Initialization
    
    public init(
        radiusPx: Double = 4.0,
        durationSec: TimeInterval = 0.450,
        minTravelPx: Double = 25.0,
        cooldownSec: TimeInterval = 0.500,
        stationaryThresholdPx: Double = 0.15,
        initialPosition: CGPoint = .zero
    ) {
        self.radiusPx = radiusPx
        self.durationSec = durationSec
        self.minTravelPx = minTravelPx
        self.cooldownSec = cooldownSec
        self.stationaryThresholdPx = stationaryThresholdPx
        self.virtualCursorPosition = initialPosition
    }
    
    public init(config: EngineConfig, initialPosition: CGPoint = .zero) {
        self.radiusPx = config.hoverDwellRadiusPx
        self.durationSec = config.hoverDwellDurationSec
        self.minTravelPx = config.hoverDwellMinTravelPx
        self.cooldownSec = config.hoverDwellCooldownSec
        self.stationaryThresholdPx = 0.15
        self.virtualCursorPosition = initialPosition
    }
    
    // MARK: - Processing Pipeline
    
    /// Evaluates cursor displacements, tracks spatial dwelling, and emits hover-dwell clicks.
    public mutating func process(
        delta: CursorDelta,
        dt: TimeInterval = 0.010
    ) -> ClickType? {
        guard delta.dx.isFinite, delta.dy.isFinite, dt.isFinite, dt > 0.0 else {
            return nil
        }

        let nextX = virtualCursorPosition.x + delta.dx
        let nextY = virtualCursorPosition.y + delta.dy
        let stepDist = hypot(delta.dx, delta.dy)
        guard nextX.isFinite, nextY.isFinite, stepDist.isFinite else {
            return nil
        }

        virtualCursorPosition.x = nextX
        virtualCursorPosition.y = nextY
        
        var clickToEmit: ClickType? = nil
        
        switch state {
        case .idle:
            accumulatedTravel += stepDist
            if accumulatedTravel >= minTravelPx {
                state = .armed
            }
            
        case .armed:
            accumulatedTravel += stepDist
            // When cursor slows down to dwell speed, latch anchor point
            if stepDist <= stationaryThresholdPx {
                let initialDwellTime = dt
                if initialDwellTime >= durationSec {
                    clickToEmit = .leftClick(source: "hover_dwell")
                    state = .cooldown(remainingSec: cooldownSec)
                    accumulatedTravel = 0.0
                } else {
                    state = .dwelling(anchor: virtualCursorPosition, dwellTime: initialDwellTime)
                }
            }
            
        case .dwelling(let anchor, var dwellTime):
            let distFromAnchor = hypot(
                virtualCursorPosition.x - anchor.x,
                virtualCursorPosition.y - anchor.y
            )
            
            if distFromAnchor.isFinite && distFromAnchor <= radiusPx {
                dwellTime += dt
                if dwellTime >= durationSec {
                    clickToEmit = .leftClick(source: "hover_dwell")
                    state = .cooldown(remainingSec: cooldownSec)
                    accumulatedTravel = 0.0
                } else {
                    state = .dwelling(anchor: anchor, dwellTime: dwellTime)
                }
            } else {
                // Escaped anchor radius -> abort to idle
                state = .idle
                accumulatedTravel = 0.0
            }
            
        case .cooldown(var remaining):
            remaining -= dt
            if remaining <= 1e-6 {
                state = .idle
                accumulatedTravel = 0.0
            } else {
                state = .cooldown(remainingSec: remaining)
            }
        }
        
        return clickToEmit
    }
    
    /// Aborts any active dwell and resets state to idle.
    public mutating func abort() {
        state = .idle
        accumulatedTravel = 0.0
    }
    
    /// Full reset of FSM and accumulated travel.
    public mutating func reset() {
        state = .idle
        accumulatedTravel = 0.0
    }
    
    /// Manually aligns the internal virtual cursor tracking point.
    public mutating func setCursorPosition(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        virtualCursorPosition = point
    }
}

/// Unified Gesture Click Engine combining Roll-Twist and Hover-Dwell gesture detection.
public struct GestureClickEngine: Sendable, Equatable {
    
    public var rollTwistDetector: RollTwistClickDetector
    public var hoverDwellDetector: HoverDwellClickDetector
    
    public init(config: EngineConfig = EngineConfig()) {
        self.rollTwistDetector = RollTwistClickDetector(config: config)
        self.hoverDwellDetector = HoverDwellClickDetector(config: config)
    }
    
    /// Processes decoupled motion rates and raw ballistics deltas, managing cursor delta locking and click emissions.
    public mutating func process(
        pitchRate: Double,
        yawRate: Double,
        rollRate: Double,
        rawDelta: CursorDelta,
        timestamp: TimeInterval,
        dt: TimeInterval
    ) -> (delta: CursorDelta, clicks: [ClickType]) {
        // Stage 1: Roll-Twist Detection & Locking
        let (twistClick, isLocked) = rollTwistDetector.process(
            pitchRate: pitchRate,
            yawRate: yawRate,
            rollRate: rollRate,
            timestamp: timestamp,
            dt: dt
        )
        
        // Stage 2: Enforce Predictive Lock on Cursor Delta
        let finalDelta: CursorDelta
        if isLocked {
            finalDelta = CursorDelta(dx: 0.0, dy: 0.0, isLocked: true, timestamp: timestamp)
        } else {
            finalDelta = CursorDelta(dx: rawDelta.dx, dy: rawDelta.dy, isLocked: false, timestamp: timestamp)
        }
        
        // Stage 3: Hover-Dwell Processing (Roll twist takes absolute precedence and aborts dwell)
        var clicksToEmit: [ClickType] = []
        
        if let tc = twistClick {
            clicksToEmit.append(tc)
            hoverDwellDetector.abort()
        } else {
            // Also abort dwell if roll twist onset lock is active
            if abs(rollRate) >= rollTwistDetector.onsetLockThresholdRadS {
                hoverDwellDetector.abort()
            } else if let dc = hoverDwellDetector.process(delta: finalDelta, dt: dt) {
                clicksToEmit.append(dc)
            }
        }
        
        return (finalDelta, clicksToEmit)
    }
    
    /// Full reset of gesture engines.
    public mutating func reset() {
        rollTwistDetector.reset()
        hoverDwellDetector.reset()
    }
}
