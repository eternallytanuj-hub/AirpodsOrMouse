//
//  AdaptiveOneEuroFilter.swift
//  AirPodWandCore
//
//  Milestone 3: Dual-Axis Adaptive 1€ Tremor Suppression Filter
//

import Foundation

/// Pure-software implementation of the 1€ (One Euro) Adaptive Smoothing Filter (Casiez et al., 2012).
/// Dynamically adjusts cutoff frequency based on instantaneous speed derivative to eliminate hand tremor
/// while maintaining sub-10 ms flick latency.
public struct OneEuroFilter: Sendable, Equatable {
    
    // MARK: - Filter Coefficients
    
    /// Minimum cutoff frequency in Hz for low velocities (suppresses tremor, default 0.8 Hz).
    public let minCutoff: Double
    
    /// Speed coefficient scaling cutoff frequency with velocity derivative (default 0.40).
    public let beta: Double
    
    /// Cutoff frequency in Hz for derivative smoothing (default 1.0 Hz).
    public let dCutoff: Double
    
    // MARK: - State Memory
    
    private var xPrev: Double?
    private var dxPrev: Double = 0.0
    private var tPrev: TimeInterval?
    
    // MARK: - Initialization
    
    public init(minCutoff: Double = 0.8, beta: Double = 0.40, dCutoff: Double = 1.0) {
        self.minCutoff = (minCutoff.isFinite && minCutoff > 0.0) ? minCutoff : 0.8
        self.beta = (beta.isFinite && beta >= 0.0) ? beta : 0.40
        self.dCutoff = (dCutoff.isFinite && dCutoff > 0.0) ? dCutoff : 1.0
    }
    
    // MARK: - Discretization Helper
    
    @inline(__always)
    private func alpha(cutoff: Double, dt: Double) -> Double {
        guard cutoff.isFinite, cutoff > 0.0, dt.isFinite, dt > 0.0 else {
            return 0.0
        }
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        let ratio = tau / dt
        guard ratio.isFinite else { return 0.0 }
        return 1.0 / (1.0 + ratio)
    }
    
    // MARK: - Filtering Pipeline
    
    /// Filters an incoming 1D scalar signal sample against its monotonic timestamp.
    public mutating func filter(value: Double, timestamp: TimeInterval) -> Double {
        // Defensive input validation for value AND timestamp
        guard value.isFinite, timestamp.isFinite else { return xPrev ?? 0.0 }
        
        guard let prevX = xPrev, let prevT = tPrev else {
            self.xPrev = value
            self.tPrev = timestamp
            self.dxPrev = 0.0
            return value
        }
        
        let dt = timestamp - prevT
        // Reject non-finite, non-positive, or sub-microsecond intervals
        guard dt.isFinite, dt > 1e-6 else { return prevX }
        
        // Re-arm state if sample interval exceeds maximum discontinuity threshold (e.g. 200 ms pause)
        if dt > 0.20 {
            self.xPrev = value
            self.tPrev = timestamp
            self.dxPrev = 0.0
            return value
        }
        
        // Step 1: Compute discrete raw derivative
        let rawDx = (value - prevX) / dt
        guard rawDx.isFinite else {
            self.xPrev = value
            self.dxPrev = 0.0
            self.tPrev = timestamp
            return value
        }
        
        // Step 2: Filter derivative with fixed cutoff f_{c, d}
        let alphaD = alpha(cutoff: dCutoff, dt: dt)
        let filteredDx = alphaD * rawDx + (1.0 - alphaD) * dxPrev
        guard filteredDx.isFinite else {
            self.xPrev = value
            self.dxPrev = 0.0
            self.tPrev = timestamp
            return value
        }
        
        // Step 3: Compute adaptive cutoff frequency
        let adaptiveCutoff = minCutoff + beta * abs(filteredDx)
        guard adaptiveCutoff.isFinite, adaptiveCutoff > 0.0 else {
            self.xPrev = value
            self.dxPrev = 0.0
            self.tPrev = timestamp
            return value
        }
        
        // Step 4: Filter signal state with adaptive cutoff
        let alphaSignal = alpha(cutoff: adaptiveCutoff, dt: dt)
        let filteredX = alphaSignal * value + (1.0 - alphaSignal) * prevX
        guard filteredX.isFinite else {
            self.xPrev = value
            self.dxPrev = 0.0
            self.tPrev = timestamp
            return value
        }
        
        // Step 5: Update persistent filter state
        self.xPrev = filteredX
        self.dxPrev = filteredDx
        self.tPrev = timestamp
        
        return filteredX
    }
    
    /// Resets filter history.
    public mutating func reset() {
        self.xPrev = nil
        self.dxPrev = 0.0
        self.tPrev = nil
    }
}

/// Dual-Axis Adaptive 1€ Filter managing independent orthogonal filtering channels (Pitch & Yaw).
public struct AdaptiveOneEuroFilter: Sendable, Equatable {
    
    public var pitchFilter: OneEuroFilter
    public var yawFilter: OneEuroFilter
    
    public init(minCutoff: Double = 0.8, beta: Double = 0.40, dCutoff: Double = 1.0) {
        self.pitchFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        self.yawFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }
    
    public init(minCutoff: Double, beta: Double, derCutoff: Double) {
        self.pitchFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: derCutoff)
        self.yawFilter = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: derCutoff)
    }
    
    public init(config: EngineConfig) {
        self.pitchFilter = OneEuroFilter(
            minCutoff: config.oneEuroMinCutoff,
            beta: config.oneEuroBeta,
            dCutoff: config.oneEuroDercutoff
        )
        self.yawFilter = OneEuroFilter(
            minCutoff: config.oneEuroMinCutoff,
            beta: config.oneEuroBeta,
            dCutoff: config.oneEuroDercutoff
        )
    }
    
    /// Filters orthogonal 2D angular velocity components independently.
    public mutating func filter(pitch: Double, yaw: Double, timestamp: TimeInterval) -> (pitch: Double, yaw: Double) {
        let filteredPitch = pitchFilter.filter(value: pitch, timestamp: timestamp)
        let filteredYaw = yawFilter.filter(value: yaw, timestamp: timestamp)
        return (filteredPitch, filteredYaw)
    }
    
    /// Filters a single scalar value through the primary pitch filter channel.
    public mutating func filter(value: Double, timestamp: TimeInterval) -> Double {
        pitchFilter.filter(value: value, timestamp: timestamp)
    }
    
    /// Resets state on both filter axes.
    public mutating func reset() {
        pitchFilter.reset()
        yawFilter.reset()
    }
}
