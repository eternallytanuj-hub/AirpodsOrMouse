//
//  MotionAndClickEngine.swift
//  AirPodWandCore
//
//  Milestone 3: 6-DoF Motion DSP & Software Gesture Click Engine
//

import Foundation
import simd

/// Central 6-DoF Motion DSP, Ballistics, and Software Gesture Click Engine actor.
///
/// Integrates the 5 processing stages in sequential, thread-safe order:
/// 1. `AutoCalibrator`: Steady attitude capture & grip tilt decoupling via q_ref* ⊗ ω ⊗ q_ref.
/// 2. `AdaptiveOneEuroFilter`: Dual-axis adaptive tremor suppression (pitch & yaw channels).
/// 3. `SigmoidBallistics`: 5-parameter generalized logistic velocity gain & macOS screen projection.
/// 4. `GestureClickEngine`:
///    - Axial roll-twist detection with predictive cursor locking (0.00 px wander) and 400 ms debounce.
///    - Hover-dwell 4-state FSM with 25 px approach priming, 450 ms dwell in 4 px radius, and single-shot disarm.
/// 5. Stem Media Command Hooks: Ingestion of `MPRemoteCommandCenter` stem clicks (.leftClick(source: "stem_pinch")).
public actor MotionAndClickEngine {
    
    // MARK: - Properties
    
    public let config: EngineConfig
    
    public private(set) var autoCalibrator: AutoCalibrator
    public private(set) var filter: AdaptiveOneEuroFilter
    public let ballistics: SigmoidBallistics
    public private(set) var gestureEngine: GestureClickEngine
    
    private var pendingStemClicks: [ClickType] = []
    private var lastFrameTimestamp: TimeInterval?
    
    // MARK: - Initialization
    
    public init(config: EngineConfig = EngineConfig()) {
        self.config = config
        self.autoCalibrator = AutoCalibrator(config: config)
        self.filter = AdaptiveOneEuroFilter(config: config)
        self.ballistics = SigmoidBallistics(config: config)
        self.gestureEngine = GestureClickEngine(config: config)
    }
    
    // MARK: - Pipeline Processing
    
    /// Processes a single 6-DoF MotionFrame through the full DSP and gesture pipeline,
    /// optionally dispatching displacements and click events to a `CursorEventSink`.
    ///
    /// - Parameters:
    ///   - frame: The raw incoming 6-DoF `MotionFrame`.
    ///   - sink: Optional event sink to post cursor deltas and clicks to.
    /// - Returns: A tuple of the resulting `CursorDelta` and any emitted `[ClickType]` clicks.
    @discardableResult
    public func process(
        frame: MotionFrame,
        sink: (any CursorEventSink)? = nil
    ) async -> (delta: CursorDelta, clicks: [ClickType]) {
        let validTimestamp = frame.timestamp.isFinite ? frame.timestamp : (lastFrameTimestamp ?? 0.0)
        let dt: TimeInterval
        if let lastT = lastFrameTimestamp, validTimestamp > lastT {
            dt = min(max(validTimestamp - lastT, 0.001), 0.100)
        } else {
            let safeRate = (config.sampleRateHz.isFinite && config.sampleRateHz > 0.0) ? config.sampleRateHz : 100.0
            dt = min(max(1.0 / safeRate, 0.001), 0.100)
        }
        if frame.timestamp.isFinite {
            lastFrameTimestamp = frame.timestamp
        }
        
        // Stage 1: Auto-Calibration & Grip Tilt Decoupling
        let wasCalibrated = autoCalibrator.isCalibrated
        let wasSettling = autoCalibrator.isInPostCalibrationSettle
        let rawDecoupled = autoCalibrator.process(frame: frame)
        let isNowCalibrated = autoCalibrator.isCalibrated
        let isNowSettling = autoCalibrator.isInPostCalibrationSettle
        
        if config.useGravityHorizonCalibration {
            let calibrationTransitionedReady = (!wasCalibrated && isNowCalibrated && !isNowSettling) || (wasSettling && !isNowSettling)
            if calibrationTransitionedReady {
                filter.reset()
                gestureEngine.reset()
            }
            if !isNowCalibrated || wasSettling || isNowSettling {
                var earlyClicks: [ClickType] = []
                if !pendingStemClicks.isEmpty {
                    earlyClicks.append(contentsOf: pendingStemClicks)
                    pendingStemClicks.removeAll(keepingCapacity: true)
                }
                let zeroDelta = CursorDelta(dx: 0.0, dy: 0.0, isLocked: false, timestamp: validTimestamp)
                if let sink = sink {
                    await sink.postMove(delta: zeroDelta)
                    for click in earlyClicks {
                        await sink.postClick(type: click)
                    }
                }
                return (zeroDelta, earlyClicks)
            }
        }
        
        let decoupledRates = (rawDecoupled.x.isFinite && rawDecoupled.y.isFinite && rawDecoupled.z.isFinite)
            ? rawDecoupled
            : .zero
        
        // Stage 2: Dual-Axis Adaptive 1€ Tremor Filter
        let (filteredPitch, filteredYaw) = filter.filter(
            pitch: decoupledRates.x,
            yaw: decoupledRates.y,
            timestamp: validTimestamp
        )
        
        // Stage 3: Sigmoid Velocity Ballistics & Screen Projection
        var rawDelta = ballistics.calculateDelta(
            pitchRate: filteredPitch,
            yawRate: filteredYaw,
            dt: dt,
            timestamp: validTimestamp
        )
        
        if config.invertX || config.invertY {
            let flippedDx = (config.invertX && rawDelta.dx != 0.0) ? -rawDelta.dx : rawDelta.dx
            let flippedDy = (config.invertY && rawDelta.dy != 0.0) ? -rawDelta.dy : rawDelta.dy
            rawDelta = CursorDelta(
                dx: flippedDx,
                dy: flippedDy,
                isLocked: rawDelta.isLocked,
                timestamp: rawDelta.timestamp
            )
        }
        
        // Stage 4: Gesture Click Engine & Cursor Delta Locking
        let (finalDelta, initialClicks) = gestureEngine.process(
            pitchRate: decoupledRates.x,
            yawRate: decoupledRates.y,
            rollRate: decoupledRates.z,
            rawDelta: rawDelta,
            timestamp: validTimestamp,
            dt: dt
        )
        var clicks = initialClicks
        
        // Stage 5: Drain any pending stem media pinch clicks
        if !pendingStemClicks.isEmpty {
            clicks.append(contentsOf: pendingStemClicks)
            pendingStemClicks.removeAll(keepingCapacity: true)
        }
        
        // Post to sink if provided
        if let sink = sink {
            await sink.postMove(delta: finalDelta)
            for click in clicks {
                await sink.postClick(type: click)
            }
        }
        
        return (finalDelta, clicks)
    }
    
    // MARK: - Stem Media Hook Integration
    
    /// Hooks MPRemoteCommandCenter stem pinching events to inject click actions into the stream.
    public func injectStemClick(type: ClickType = .leftClick(source: "stem_pinch")) {
        pendingStemClicks.append(type)
    }

    /// Drains and optionally dispatches any queued stem pinch clicks when ending a stream.
    @discardableResult
    public func flushPendingStemClicks(sink: (any CursorEventSink)? = nil) async -> [ClickType] {
        guard !pendingStemClicks.isEmpty else { return [] }
        let flushed = pendingStemClicks
        pendingStemClicks.removeAll(keepingCapacity: false)
        if let sink = sink {
            for click in flushed {
                await sink.postClick(type: click)
            }
        }
        return flushed
    }
    
    // MARK: - Calibration Control
    
    /// Forces immediate calibration to a known attitude quaternion (useful for testing and deterministic resets).
    public func forceCalibrate(_ quat: simd_quatd) {
        autoCalibrator.forceCalibrate(quat)
    }
    
    /// Forces immediate calibration using explicit screen basis vectors (right, forward, up) in body coordinates.
    public func forceCalibrateBasis(right: simd_double3, forward: simd_double3, up: simd_double3) {
        autoCalibrator.forceCalibrateBasis(right: right, forward: forward, up: up)
        filter.reset()
        gestureEngine.reset()
    }
    
    /// Recalibrates reference orientation. If quaternion is nil, requests automatic recalibration upon next settle.
    public func recalibrate(quaternion: simd_quatd? = nil) {
        autoCalibrator.recalibrate(quaternion: quaternion)
        if quaternion == nil && config.useGravityHorizonCalibration {
            filter.reset()
            gestureEngine.reset()
        }
    }
    
    /// State queries
    public var isCalibrated: Bool {
        autoCalibrator.isCalibrated
    }
    
    public var calibrationPhase: CalibrationPhase {
        autoCalibrator.calibrationPhase
    }
    
    public var screenRightAxis: simd_double3 {
        autoCalibrator.screenRightAxis
    }
    
    public var screenUpAxis: simd_double3 {
        autoCalibrator.screenUpAxis
    }
    
    public var screenForwardAxis: simd_double3 {
        autoCalibrator.screenForwardAxis
    }
    
    public var referenceQuaternion: simd_quatd {
        autoCalibrator.referenceQuaternion
    }
    
    public var needsRecalibration: Bool {
        autoCalibrator.needsRecalibration
    }
    
    // MARK: - Reset
    
    /// Resets all internal engine state across all 5 stages.
    public func reset() {
        autoCalibrator.reset()
        filter.reset()
        gestureEngine.reset()
        pendingStemClicks.removeAll(keepingCapacity: false)
        lastFrameTimestamp = nil
    }
}
