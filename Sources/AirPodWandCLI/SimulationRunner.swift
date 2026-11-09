//
//  SimulationRunner.swift
//  AirPodWandCLI
//
//  Pure-software closed-loop synthetic verification session (Requirement R3, R4, Feature 20).
//  Asserts trajectory RMSE <= 3.5 px, zero locked wander, cross-axis coupling < 2.0%,
//  and exact click counts, outputting E2E_SOFTWARE_VERIFICATION_PASSED with exit code 0.
//

import Foundation
import CoreGraphics
import simd
import AirPodWandCore

/// Runs the 100% headless synthetic closed-loop verification session.
public struct SimulationRunner: Sendable {

    /// Executes closed-loop verification, streams frames, evaluates oracles, and returns SimulationResult.
    public static func evaluate(
        sampleRateHz: Double = 100.0,
        expectedCwClicks: Int = 1,
        expectedCcwClicks: Int = 1,
        expectedDwellClicks: Int = 1
    ) async -> SimulationResult {
        let engine = MotionAndClickEngine()
        let initialPos = CGPoint(x: 960, y: 540)
        let spy = SoftwareEventSpy(initialPosition: initialPos)

        // 1. Acquire synthetic frames from comprehensive suite (630 frames at 100 Hz);
        // Step 1 (first 50 quiescent frames) naturally auto-calibrates grip reference tilt.
        let frames = VirtualMotionGenerator.generateFrames(for: .comprehensiveSuite, sampleRateHz: sampleRateHz)

        // 2. Stream all frames through the complete 5-stage DSP engine into SoftwareEventSpy
        for frame in frames {
            await engine.process(frame: frame, sink: spy)
        }

        // 3. Compute analytical ground-truth trajectory for Lissajous figure-eight (frames 50..<350)
        var expectedPositions: [CGPoint] = Array(repeating: initialPos, count: 50)
        let dt = 1.0 / sampleRateHz
        let ballistics = SigmoidBallistics()
        var filter = AdaptiveOneEuroFilter()
        var pos = initialPos

        // Prime the filter with the 50 quiescent rest frames (matching engine's filter state)
        for k in 0..<50 {
            _ = filter.filter(pitch: 0.0, yaw: 0.0, timestamp: Double(k) * dt)
        }

        for k in 0..<300 {
            let t = Double(k) * dt
            let pitchRate = 0.15 * 4.0 * .pi * 0.5 * cos(4.0 * .pi * 0.5 * t)
            let yawRate = 0.30 * 2.0 * .pi * 0.5 * cos(2.0 * .pi * 0.5 * t)
            let filtered = filter.filter(pitch: pitchRate, yaw: yawRate, timestamp: 0.5 + t)
            let delta = ballistics.calculateDelta(pitchRate: filtered.pitch, yawRate: filtered.yaw, dt: dt, timestamp: 0.5 + t)
            pos.x += delta.dx
            pos.y += delta.dy
            expectedPositions.append(pos)
        }


        // 4. Evaluate against all closed-loop verification oracles
        return await spy.evaluate(
            expectedTrajectory: expectedPositions,
            maxRmse: 3.5,
            maxCrossAxisCoupling: 2.0,
            expectedCwClicks: expectedCwClicks,
            expectedCcwClicks: expectedCcwClicks,
            expectedDwellClicks: expectedDwellClicks,
            figureEightRange: 50..<350,
            yawRange: 360..<390
        )
    }

    /// Runs verification session from the CLI, prints diagnostic banner, and returns exit code status.
    @discardableResult
    public static func run(
        sampleRateHz: Double = 100.0,
        expectedCwClicks: Int = 1,
        expectedCcwClicks: Int = 1,
        expectedDwellClicks: Int = 1
    ) async -> Bool {
        print("=======================================================")
        print("Starting AirPodWand Synthetic Closed-Loop Verification")
        print("Sample Rate: \(sampleRateHz) Hz | Pure-Software Headless Mode")
        print("=======================================================\n")

        let result = await evaluate(
            sampleRateHz: sampleRateHz,
            expectedCwClicks: expectedCwClicks,
            expectedCcwClicks: expectedCcwClicks,
            expectedDwellClicks: expectedDwellClicks
        )

        print(result.description)
        print("")

        if result.passed {
            print("=======================================================")
            print("E2E_SOFTWARE_VERIFICATION_PASSED")
            print("=======================================================")
            fflush(stdout)
            return true
        } else {
            fputs("E2E_SOFTWARE_VERIFICATION_FAILED:\n", stderr)
            for reason in result.failureReasons {
                fputs("  - \(reason)\n", stderr)
            }
            fflush(stderr)
            return false
        }
    }
}
