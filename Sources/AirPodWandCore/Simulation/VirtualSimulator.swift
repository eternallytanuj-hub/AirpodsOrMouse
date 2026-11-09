import Foundation
import CoreGraphics
import simd
import os

// MARK: - Virtual Motion Generator

/// Pure-software synthetic motion generator producing deterministic 100 Hz MotionFrame streams.
public actor VirtualMotionGenerator: MotionSourceProtocol {
    
    /// Available synthetic motion scenario profiles.
    public enum Profile: Sendable, Equatable {
        /// Smooth 2D Lissajous figure-eight trajectory.
        case lissajousFigureEight(
            duration: TimeInterval = 4.0,
            frequencyHz: Double = 0.5,
            amplitudePitch: Double = 0.15,
            amplitudeYaw: Double = 0.30
        )
        
        /// Approach travel (>25 px) followed by 9 Hz tremor and 450 ms hover-dwell hold.
        case tremorWithHoverDwell(
            approachDuration: TimeInterval = 0.4,
            dwellDuration: TimeInterval = 1.0,
            tremorFrequencyHz: Double = 9.0,
            tremorAmplitude: Double = 0.030
        )
        
        /// Bidirectional axial roll-twist bursts exceeding 4.2 rad/s CW and CCW.
        case axialRollTwistBursts(
            cwPeak: Double = 6.0,
            ccwPeak: Double = -6.0,
            burstDuration: TimeInterval = 0.15,
            cooldownDuration: TimeInterval = 0.45
        )
        
        /// Unified verification suite combining calibration, Lissajous, dwell, and roll twists.
        case comprehensiveSuite
    }
    
    /// Pacing mode for stream generation.
    public enum Pace: Sendable, Equatable {
        /// Paced real-time streaming emitting 1 frame every 10 ms (100 Hz).
        case realTime
        /// Instant unpaced streaming yielding all frames immediately (for fast headless unit tests).
        case immediate
    }
    
    public let profile: Profile
    public let pace: Pace
    public let sampleRateHz: Double
    private var streamingTask: Task<Void, Never>?
    public private(set) var isStreaming: Bool = false
    
    public init(
        profile: Profile = .comprehensiveSuite,
        pace: Pace = .immediate,
        sampleRateHz: Double = 100.0
    ) {
        self.profile = profile
        self.pace = pace
        self.sampleRateHz = sampleRateHz
    }
    
    // MARK: - MotionSourceProtocol
    
    public func start() async throws -> AsyncStream<MotionFrame> {
        stopStreaming()
        isStreaming = true
        let frames = Self.generateFrames(for: profile, sampleRateHz: sampleRateHz)
        let paceMode = self.pace
        
        return AsyncStream { continuation in
            let task = Task {
                for frame in frames {
                    if Task.isCancelled { break }
                    continuation.yield(frame)
                    if paceMode == .realTime {
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms at 100 Hz
                    }
                }
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
            
            self.streamingTask = task
        }
    }
    
    public func stop() async {
        stopStreaming()
    }
    
    private func stopStreaming() {
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil
    }
    
    // MARK: - Static Mathematical Scenario Generators
    
    /// Generates static frame sequences deterministically without asynchronous overhead.
    public nonisolated static func generateFrames(
        for profile: Profile,
        sampleRateHz: Double = 100.0
    ) -> [MotionFrame] {
        let dt = 1.0 / sampleRateHz
        
        switch profile {
        case .lissajousFigureEight(let duration, let freq, let ampPitch, let ampYaw):
            return generateLissajous(
                duration: duration,
                frequencyHz: freq,
                amplitudePitch: ampPitch,
                amplitudeYaw: ampYaw,
                dt: dt
            )
            
        case .tremorWithHoverDwell(let approachDur, let dwellDur, let tremorFreq, let tremorAmp):
            return generateTremorAndDwell(
                approachDuration: approachDur,
                dwellDuration: dwellDur,
                tremorFrequencyHz: tremorFreq,
                tremorAmplitude: tremorAmp,
                dt: dt
            )
            
        case .axialRollTwistBursts(let cwPeak, let ccwPeak, let burstDur, let cooldownDur):
            return generateRollTwistBursts(
                cwPeak: cwPeak,
                ccwPeak: ccwPeak,
                burstDuration: burstDur,
                cooldownDuration: cooldownDur,
                dt: dt
            )
            
        case .comprehensiveSuite:
            return generateComprehensiveSuite(dt: dt)
        }
    }
    
    /// Integrates angular velocity into attitude quaternion using the exact axis-angle exponential map:
    /// delta_q = simd_quatd(angle: theta, axis: omega / norm(omega))
    /// q_{k+1} = simd_normalize(q_k * delta_q)
    public nonisolated static func integrateAttitude(
        current: simd_quatd,
        angularVelocity: simd_double3,
        dt: Double
    ) -> simd_quatd {
        guard dt.isFinite, dt > 0.0,
              angularVelocity.x.isFinite, angularVelocity.y.isFinite, angularVelocity.z.isFinite,
              current.vector.x.isFinite, current.vector.y.isFinite,
              current.vector.z.isFinite, current.vector.w.isFinite else {
            return current
        }

        let speed = simd_length(angularVelocity)
        let theta = speed * dt
        guard speed.isFinite, theta.isFinite, theta > 1e-12 else { return current }
        
        let axis = angularVelocity / speed
        guard axis.x.isFinite, axis.y.isFinite, axis.z.isFinite else { return current }

        let deltaQuat = simd_quatd(angle: theta, axis: axis)
        let updated = simd_normalize(current * deltaQuat)
        guard updated.vector.x.isFinite, updated.vector.y.isFinite,
              updated.vector.z.isFinite, updated.vector.w.isFinite else {
            return current
        }
        return updated
    }
    
    // MARK: - Scenario Implementations
    
    private nonisolated static func generateLissajous(
        duration: TimeInterval,
        frequencyHz: Double,
        amplitudePitch: Double,
        amplitudeYaw: Double,
        dt: Double
    ) -> [MotionFrame] {
        let frameCount = Int(duration / dt)
        var frames: [MotionFrame] = []
        frames.reserveCapacity(frameCount)
        
        var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        
        for k in 0..<frameCount {
            let t = Double(k) * dt
            let pitchRate = amplitudePitch * 4.0 * .pi * frequencyHz * cos(4.0 * .pi * frequencyHz * t)
            let yawRate = amplitudeYaw * 2.0 * .pi * frequencyHz * cos(2.0 * .pi * frequencyHz * t)
            let omega = simd_double3(pitchRate, yawRate, 0.0)
            
            q = integrateAttitude(current: q, angularVelocity: omega, dt: dt)
            frames.append(MotionFrame(
                timestamp: t,
                attitudeQuaternion: q,
                rotationRate: omega,
                userAcceleration: .zero
            ))
        }
        return frames
    }
    
    private nonisolated static func generateTremorAndDwell(
        approachDuration: TimeInterval,
        dwellDuration: TimeInterval,
        tremorFrequencyHz: Double,
        tremorAmplitude: Double,
        dt: Double
    ) -> [MotionFrame] {
        let totalDuration = approachDuration + dwellDuration
        let frameCount = Int(totalDuration / dt)
        var frames: [MotionFrame] = []
        frames.reserveCapacity(frameCount)
        
        var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        
        for k in 0..<frameCount {
            let t = Double(k) * dt
            let omega: simd_double3
            
            if t < approachDuration {
                // Constant approach yaw movement > 25 px
                omega = simd_double3(0.0, 1.0, 0.0)
            } else {
                // Stationary dwell with 6-12 Hz hand tremor
                let tremorX = tremorAmplitude * cos(2.0 * .pi * tremorFrequencyHz * t)
                let tremorY = tremorAmplitude * sin(2.0 * .pi * tremorFrequencyHz * t)
                omega = simd_double3(tremorX, tremorY, 0.0)
            }
            
            q = integrateAttitude(current: q, angularVelocity: omega, dt: dt)
            frames.append(MotionFrame(
                timestamp: t,
                attitudeQuaternion: q,
                rotationRate: omega,
                userAcceleration: .zero
            ))
        }
        return frames
    }
    
    private nonisolated static func generateRollTwistBursts(
        cwPeak: Double,
        ccwPeak: Double,
        burstDuration: TimeInterval,
        cooldownDuration: TimeInterval,
        dt: Double
    ) -> [MotionFrame] {
        let t0: TimeInterval = 0.20
        let t1 = t0 + burstDuration
        let t2 = t1 + cooldownDuration
        let t3 = t2 + burstDuration
        let totalDuration = t3 + cooldownDuration
        
        let frameCount = Int(totalDuration / dt)
        var frames: [MotionFrame] = []
        frames.reserveCapacity(frameCount)
        
        var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        
        for k in 0..<frameCount {
            let t = Double(k) * dt
            let omega: simd_double3
            
            if t >= t0 && t < t1 {
                let phase = (t - t0) / burstDuration
                let roll = cwPeak * sin(.pi * phase)
                let wobblePitch = 0.10 * sin(.pi * phase)
                let wobbleYaw = 0.05 * sin(.pi * phase)
                omega = simd_double3(wobblePitch, wobbleYaw, roll)
            } else if t >= t2 && t < t3 {
                let phase = (t - t2) / burstDuration
                let roll = ccwPeak * sin(.pi * phase)
                let wobblePitch = 0.10 * sin(.pi * phase)
                let wobbleYaw = 0.05 * sin(.pi * phase)
                omega = simd_double3(wobblePitch, wobbleYaw, roll)
            } else {
                omega = .zero
            }
            
            q = integrateAttitude(current: q, angularVelocity: omega, dt: dt)
            frames.append(MotionFrame(
                timestamp: t,
                attitudeQuaternion: q,
                rotationRate: omega,
                userAcceleration: .zero
            ))
        }
        return frames
    }
    
    private nonisolated static func generateComprehensiveSuite(dt: Double) -> [MotionFrame] {
        // Step 1: Calibration (0.0 - 0.5s) steady rest with grip tilt (pitch 30 deg, roll 20 deg)
        let calibCount = Int(0.5 / dt)
        var frames: [MotionFrame] = []
        
        let tiltPitch = simd_quatd(angle: 30.0 * .pi / 180.0, axis: simd_double3(1, 0, 0))
        let tiltRoll = simd_quatd(angle: 20.0 * .pi / 180.0, axis: simd_double3(0, 0, 1))
        let initialTilt = simd_normalize(tiltPitch * tiltRoll)
        
        for k in 0..<calibCount {
            frames.append(MotionFrame(
                timestamp: Double(k) * dt,
                attitudeQuaternion: initialTilt,
                rotationRate: .zero,
                userAcceleration: .zero
            ))
        }
        
        // Step 2: Lissajous Figure-Eight (3.0s, 300 frames)
        let lissajous = generateLissajous(
            duration: 3.0,
            frequencyHz: 0.5,
            amplitudePitch: 0.15,
            amplitudeYaw: 0.30,
            dt: dt
        )
        let tOffset1 = frames.last?.timestamp ?? 0.0
        for f in lissajous {
            let combinedAttitude = simd_normalize(initialTilt * f.attitudeQuaternion)
            let rotatedRate = simd_act(initialTilt, f.rotationRate)
            frames.append(MotionFrame(
                timestamp: tOffset1 + f.timestamp + dt,
                attitudeQuaternion: combinedAttitude,
                rotationRate: rotatedRate,
                userAcceleration: .zero
            ))
        }
        
        // Step 3: Tremor with Hover-Dwell (1.4s, 140 frames)
        let dwell = generateTremorAndDwell(
            approachDuration: 0.4,
            dwellDuration: 1.0,
            tremorFrequencyHz: 9.0,
            tremorAmplitude: 0.030,
            dt: dt
        )
        let tOffset2 = frames.last?.timestamp ?? 0.0
        for f in dwell {
            let combinedAttitude = simd_normalize(initialTilt * f.attitudeQuaternion)
            let rotatedRate = simd_act(initialTilt, f.rotationRate)
            frames.append(MotionFrame(
                timestamp: tOffset2 + f.timestamp + dt,
                attitudeQuaternion: combinedAttitude,
                rotationRate: rotatedRate,
                userAcceleration: .zero
            ))
        }
        
        // Step 4: Axial Roll-Twist Bursts (1.4s, 140 frames)
        let twists = generateRollTwistBursts(
            cwPeak: 6.0,
            ccwPeak: -6.0,
            burstDuration: 0.15,
            cooldownDuration: 0.45,
            dt: dt
        )
        let tOffset3 = frames.last?.timestamp ?? 0.0
        for f in twists {
            let combinedAttitude = simd_normalize(initialTilt * f.attitudeQuaternion)
            let rotatedRate = simd_act(initialTilt, f.rotationRate)
            frames.append(MotionFrame(
                timestamp: tOffset3 + f.timestamp + dt,
                attitudeQuaternion: combinedAttitude,
                rotationRate: rotatedRate,
                userAcceleration: .zero
            ))
        }
        
        return frames
    }
}

// MARK: - Software Event Spy

/// Thread-safe actor recording and asserting all cursor movement and click events.
public actor SoftwareEventSpy: CursorEventSink {
    
    public typealias RecordedClick = AirPodWandCore.RecordedClick
    
    // MARK: - State Properties
    
    public let initialPosition: CGPoint
    public private(set) var currentPosition: CGPoint
    public private(set) var recordedDeltas: [CursorDelta] = []
    public private(set) var recordedPositions: [CGPoint] = []
    public private(set) var recordedClicks: [RecordedClick] = []
    public private(set) var frameCount: Int = 0
    public private(set) var simulatedTime: TimeInterval = 0.0
    public private(set) var frameInterval: TimeInterval = 0.01 // 100 Hz default
    public private(set) var maxLockedDelta: Double = 0.0
    public var maxLockedWander: Double { maxLockedDelta }
    public private(set) var totalDistanceTraveled: Double = 0.0
    
    // MARK: - Initialization
    
    public init(
        initialPosition: CGPoint = CGPoint(x: 960, y: 540),
        frameInterval: TimeInterval = 0.01
    ) {
        self.initialPosition = initialPosition
        self.currentPosition = initialPosition
        self.frameInterval = frameInterval
    }
    
    // MARK: - CursorEventSink Implementation
    
    public func postMove(delta: CursorDelta) async {
        guard delta.dx.isFinite, delta.dy.isFinite else { return }
        let newX = currentPosition.x + delta.dx
        let newY = currentPosition.y + delta.dy
        let stepDist = hypot(delta.dx, delta.dy)
        guard newX.isFinite, newY.isFinite, stepDist.isFinite else { return }

        recordedDeltas.append(delta)
        frameCount += 1
        simulatedTime += frameInterval
        totalDistanceTraveled += stepDist
        
        if delta.isLocked {
            maxLockedDelta = max(maxLockedDelta, stepDist)
        }
        
        // Update accumulated position
        currentPosition = CGPoint(x: newX, y: newY)
        recordedPositions.append(currentPosition)
    }
    
    public func postClick(type: ClickType) async {
        let source: String
        switch type {
        case .leftClick(let src): source = src
        case .rightClick(let src): source = src
        }
        
        let click = RecordedClick(
            type: type,
            source: source,
            position: currentPosition,
            frameIndex: frameCount,
            timestamp: simulatedTime
        )
        recordedClicks.append(click)
    }
    
    // MARK: - State Management
    
    public func reset(to position: CGPoint? = nil) {
        let resetPos = position ?? initialPosition
        currentPosition = resetPos
        recordedDeltas.removeAll(keepingCapacity: true)
        recordedPositions.removeAll(keepingCapacity: true)
        recordedClicks.removeAll(keepingCapacity: true)
        frameCount = 0
        simulatedTime = 0.0
        maxLockedDelta = 0.0
        totalDistanceTraveled = 0.0
    }
    
    // MARK: - Analytical Assertions
    
    public func clickCount(bySource source: String) -> Int {
        recordedClicks.filter { $0.source == source }.count
    }
    
    public func clicks(bySource source: String) -> [RecordedClick] {
        recordedClicks.filter { $0.source == source }
    }
    
    public func clickCount(for type: ClickType) -> Int {
        recordedClicks.filter { $0.type == type }.count
    }
    
    public func clicksHistogram() -> [String: Int] {
        var counts: [String: Int] = [:]
        for click in recordedClicks {
            counts[click.source, default: 0] += 1
        }
        return counts
    }
    
    public func distanceTraveled(in range: Range<Int>) -> Double {
        guard !recordedDeltas.isEmpty else { return 0.0 }
        let clampedStart = max(0, min(range.lowerBound, recordedDeltas.count))
        let clampedEnd = max(clampedStart, min(range.upperBound, recordedDeltas.count))
        guard clampedStart < clampedEnd else { return 0.0 }
        
        var dist = 0.0
        for i in clampedStart..<clampedEnd {
            dist += hypot(recordedDeltas[i].dx, recordedDeltas[i].dy)
        }
        return dist
    }
    
    public func trajectoryRmse(
        againstExpected expected: [CGPoint],
        range: Range<Int>? = nil
    ) -> Double {
        let actual = recordedPositions
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? min(actual.count, expected.count)
        
        guard start < end, start >= 0, end <= min(actual.count, expected.count) else {
            return 0.0
        }
        
        var sumSquaredError = 0.0
        let count = Double(end - start)
        
        for i in start..<end {
            let dx = actual[i].x - expected[i].x
            let dy = actual[i].y - expected[i].y
            sumSquaredError += (dx * dx + dy * dy)
        }
        
        return sqrt(sumSquaredError / count)
    }
    
    public func crossAxisCouplingPercentage(
        range: Range<Int>? = nil
    ) -> Double {
        let deltas = recordedDeltas
        let start = range?.lowerBound ?? 0
        let end = range?.upperBound ?? deltas.count
        
        guard start < end, start >= 0, end <= deltas.count else {
            return 0.0
        }
        
        var totalAbsDx = 0.0
        var totalAbsDy = 0.0
        for i in start..<end {
            totalAbsDx += abs(deltas[i].dx)
            totalAbsDy += abs(deltas[i].dy)
        }
        
        guard totalAbsDx > 0.0001 else { return 0.0 }
        return (totalAbsDy / totalAbsDx) * 100.0
    }
    
    public func maxDriftFromAnchor(anchor: CGPoint, in range: Range<Int>) -> Double {
        let positions = recordedPositions
        let start = max(0, min(range.lowerBound, positions.count))
        let end = max(start, min(range.upperBound, positions.count))
        guard start < end else { return 0.0 }
        
        var maxDist = 0.0
        for i in start..<end {
            let dist = hypot(positions[i].x - anchor.x, positions[i].y - anchor.y)
            maxDist = max(maxDist, dist)
        }
        return maxDist
    }
    
    // MARK: - Snapshot & Evaluation
    
    public func snapshot() -> SpySnapshot {
        SpySnapshot(
            initialPosition: initialPosition,
            currentPosition: currentPosition,
            recordedDeltas: recordedDeltas,
            recordedPositions: recordedPositions,
            recordedClicks: recordedClicks,
            frameCount: frameCount,
            simulatedTime: simulatedTime,
            maxLockedDelta: maxLockedDelta,
            totalDistanceTraveled: totalDistanceTraveled
        )
    }
    
    public func evaluate(
        expectedTrajectory: [CGPoint],
        maxRmse: Double = 3.5,
        maxCrossAxisCoupling: Double = 2.0,
        expectedCwClicks: Int = 1,
        expectedCcwClicks: Int = 1,
        expectedDwellClicks: Int = 1,
        figureEightRange: Range<Int>? = nil,
        yawRange: Range<Int>? = nil
    ) -> SimulationResult {
        var failureReasons: [String] = []
        
        let rmse = trajectoryRmse(againstExpected: expectedTrajectory, range: figureEightRange)
        if rmse > maxRmse {
            failureReasons.append("Trajectory RMSE \(String(format: "%.3f", rmse)) px exceeds limit \(maxRmse) px")
        }
        
        let coupling = crossAxisCouplingPercentage(range: yawRange)
        if coupling >= maxCrossAxisCoupling {
            failureReasons.append("Cross-axis coupling \(String(format: "%.2f", coupling))% exceeds limit \(maxCrossAxisCoupling)%")
        }
        
        if maxLockedDelta > 0.001 {
            failureReasons.append("Max delta during locked interval was \(maxLockedDelta) px; expected 0.0 px")
        }
        
        let cwClicks = clickCount(bySource: "roll_twist_cw")
        if cwClicks != expectedCwClicks {
            failureReasons.append("Expected \(expectedCwClicks) roll_twist_cw click(s), got \(cwClicks)")
        }
        
        let ccwClicks = clickCount(bySource: "roll_twist_ccw")
        if ccwClicks != expectedCcwClicks {
            failureReasons.append("Expected \(expectedCcwClicks) roll_twist_ccw click(s), got \(ccwClicks)")
        }
        
        let dwellClicks = clickCount(bySource: "hover_dwell")
        if dwellClicks != expectedDwellClicks {
            failureReasons.append("Expected \(expectedDwellClicks) hover_dwell click(s), got \(dwellClicks)")
        }
        
        let totalExpectedClicks = expectedCwClicks + expectedCcwClicks + expectedDwellClicks
        if recordedClicks.count != totalExpectedClicks {
            failureReasons.append("Total clicks count \(recordedClicks.count) != expected \(totalExpectedClicks)")
        }
        
        let passed = failureReasons.isEmpty
        
        return SimulationResult(
            totalFrames: frameCount,
            duration: simulatedTime,
            totalDistance: totalDistanceTraveled,
            trajectoryRmse: rmse,
            crossAxisCouplingPercentage: coupling,
            totalClicks: recordedClicks.count,
            clicks: recordedClicks,
            maxLockedDelta: maxLockedDelta,
            passed: passed,
            failureReasons: failureReasons
        )
    }
}

// MARK: - Spy Snapshot

/// Immutable snapshot of SoftwareEventSpy state at a point in time.
public struct SpySnapshot: Sendable, Equatable {
    public let initialPosition: CGPoint
    public let currentPosition: CGPoint
    public let recordedDeltas: [CursorDelta]
    public let recordedPositions: [CGPoint]
    public let recordedClicks: [RecordedClick]
    public let frameCount: Int
    public let simulatedTime: TimeInterval
    public let maxLockedDelta: Double
    public var maxLockedWander: Double { maxLockedDelta }
    public let totalDistanceTraveled: Double
    
    public init(
        initialPosition: CGPoint,
        currentPosition: CGPoint,
        recordedDeltas: [CursorDelta],
        recordedPositions: [CGPoint],
        recordedClicks: [RecordedClick],
        frameCount: Int,
        simulatedTime: TimeInterval,
        maxLockedDelta: Double,
        totalDistanceTraveled: Double
    ) {
        self.initialPosition = initialPosition
        self.currentPosition = currentPosition
        self.recordedDeltas = recordedDeltas
        self.recordedPositions = recordedPositions
        self.recordedClicks = recordedClicks
        self.frameCount = frameCount
        self.simulatedTime = simulatedTime
        self.maxLockedDelta = maxLockedDelta
        self.totalDistanceTraveled = totalDistanceTraveled
    }
}

// MARK: - Mock Audio Wake

/// Pure-software mock conforming to `AudioWakeProtocol` and `StemPinchHandling` for headless testing.
public final class MockAudioWake: AudioWakeProtocol, StemPinchHandling, @unchecked Sendable {
    private let stateLock = OSAllocatedUnfairLock(initialState: false)
    private let pinchHandlerLock = OSAllocatedUnfairLock<(@Sendable (StemPinchType) -> Void)?>(initialState: nil)
    
    public init(initiallyActive: Bool = false) {
        self.stateLock.withLock { $0 = initiallyActive }
    }
    
    public var isAirPodsActive: Bool {
        stateLock.withLock { $0 }
    }
    
    public func startKeepAlive() async throws {
        stateLock.withLock { $0 = true }
    }
    
    public func stopKeepAlive() async {
        stateLock.withLock { $0 = false }
    }

    public func setStemPinchHandler(_ handler: (@Sendable (StemPinchType) -> Void)?) {
        pinchHandlerLock.withLock { $0 = handler }
    }

    /// Simulates a stem media pinch event for headless pipeline testing.
    public func simulateStemPinch(_ type: StemPinchType) {
        let handler = pinchHandlerLock.withLock { $0 }
        handler?(type)
    }
}
