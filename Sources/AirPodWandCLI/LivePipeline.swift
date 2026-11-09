//
//  LivePipeline.swift
//  AirPodWandCLI
//
//  Live Driver Daemon Pipeline (Requirement R4, Features 17, 18, 19)
//  Orchestrates SoftwareAudioWake + HeadphoneMotionSource + MotionAndClickEngine + CGEventCursorSink.
//

import Foundation
import CoreGraphics
import AirPodWandCore

/// Coordinates live hardware streaming from AirPods 4 to macOS system cursor.
public struct LivePipeline: Sendable {

    /// Runs the live driver daemon until stream completion or SIGINT / SIGTERM interruption.
    public static func run(
        audioWake: any AudioWakeProtocol = SoftwareAudioWake(),
        motionSource: any MotionSourceProtocol = HeadphoneMotionSource(),
        cursorSink: any CursorEventSink = CGEventCursorSink(),
        enableSignalTrap: Bool = true,
        engineConfig: EngineConfig = EngineConfig()
    ) async throws {
        print("=======================================================")
        print("Starting AirPodWand Live macOS Cursor Daemon")
        print("CoreAudio Auto-Router + CoreMotion Headphone Pipeline")
        print("=======================================================\n")

        // 1. Accessibility permissions pre-flight check
        let isTrusted = CGEventCursorSink.isAccessibilityTrusted()
        if !isTrusted {
            print("[AirPodWand] Notice: Process does not have macOS Accessibility permissions.")
            print("[AirPodWand] Requesting prompt... (Hardware cursor warping remains active).")
            CGEventCursorSink.requestAccessibilityPermission()
        }

        // 2. Initialize DSP motion and gesture click engine & bind stem media pinch hooks
        let engine = MotionAndClickEngine(config: engineConfig)
        let stemQueue = StemEventQueue()
        let stemSource = audioWake as? any StemPinchHandling
        stemSource?.setStemPinchHandler { pinchType in
            stemQueue.enqueue(pinchType)
        }

        if engineConfig.useGravityHorizonCalibration {
            print("""
            [AirPodWand] Grip Guide (Single Right AirPod):
              • Hold the earbud lightly between thumb and index finger, with a finger
                touching the black optical in-ear sensor on the inner side (keeps H2 active).
              • Keep the stem pointing downward toward the desk and slightly forward.
              • Triple-pinch the stem at any time to recalibrate if you change your grip.
            """)
        }

        // 3. Start CoreAudio keep-alive tone and stem media hooks
        print("[AirPodWand] Initializing audio keep-alive subsystem...")
        do {
            try await audioWake.startKeepAlive()
            if audioWake.isAirPodsActive {
                print("[AirPodWand] AirPods audio routing active. 20 Hz keep-alive streaming.")
            } else {
                print("[AirPodWand] Notice: AirPods audio device not found; default system output in effect.")
            }
        } catch {
            print("[AirPodWand] Audio keep-alive initialization note: \(error.localizedDescription)")
        }

        // 4. Set up optional POSIX signal trap for graceful stream termination
        let shutdownState = ShutdownState()
        let signalTrap: SignalTrap? = enableSignalTrap ? SignalTrap { sig in
            _ = shutdownState.triggerShutdownIfNeeded {
                print("\n[AirPodWand] Signal \(sig) received. Initiating graceful shutdown...")
                stemSource?.setStemPinchHandler(nil)
                _ = stemQueue.drain()
                return Task {
                    await motionSource.stop()
                    await audioWake.stopKeepAlive()
                }
            }
        } : nil

        // 5. Start CoreMotion headphone motion stream
        print("[AirPodWand] Starting CoreMotion headphone motion stream...")
        let stream: AsyncStream<MotionFrame>
        do {
            stream = try await motionSource.start()
            print("[AirPodWand] Motion stream active at 100 Hz.")
            if engineConfig.useGravityHorizonCalibration {
                if engineConfig.requireUpTiltGestureCalibration {
                    print("[Calibration 1/2] Hold your Right AirPod steady for 0.3s to lock Earth horizon...")
                } else {
                    print("[Calibration] Quick-calibrate: Hold your Right AirPod steady for 0.3s...")
                }
            } else {
                print("[AirPodWand] System cursor active.")
            }
            print("[AirPodWand] Press Ctrl+C to terminate daemon.\n")
            fflush(stdout)
        } catch {
            print("[AirPodWand] Motion stream initialization failed: \(error)")
            stemSource?.setStemPinchHandler(nil)
            _ = stemQueue.drain()
            if let shutdownTask = shutdownState.takeShutdownTask() {
                await shutdownTask.value
            } else {
                await motionSource.stop()
            }
            await audioWake.stopKeepAlive()
            signalTrap?.teardown()
            throw error
        }

        // 6. Main processing loop: drain stem pinches in causal order before each frame
        var lastReportedPhase: CalibrationPhase = .awaitingStillness
        var announcedReady = !engineConfig.useGravityHorizonCalibration

        for await frame in stream {
            if shutdownState.isShuttingDown { break }
            for pinch in stemQueue.drain() {
                switch pinch {
                case .singlePinch:
                    await engine.injectStemClick(type: .leftClick(source: StemPinchType.singlePinch.rawValue))
                case .doublePinch:
                    await engine.injectStemClick(type: .rightClick(source: StemPinchType.doublePinch.rawValue))
                case .triplePinch:
                    await engine.recalibrate(quaternion: nil)
                    if engineConfig.useGravityHorizonCalibration {
                        lastReportedPhase = .awaitingStillness
                        announcedReady = false
                        print("\n[Calibration 1/2] Recalibration requested — hold AirPod steady for 0.3s...")
                        fflush(stdout)
                    }
                }
            }
            await engine.process(frame: frame, sink: cursorSink)
            if !announcedReady {
                let phase = await engine.calibrationPhase
                if phase != lastReportedPhase {
                    lastReportedPhase = phase
                    switch phase {
                    case .awaitingStillness:
                        break
                    case .awaitingUpTilt:
                        print("[Calibration 2/2] Tilt the Right AirPod slightly UPWARD toward the top of your screen to lock Up/Down axis...")
                        fflush(stdout)
                    case .calibrated:
                        announcedReady = true
                        print("[Calibration Complete] Screen axes locked — move cursor smoothly with wrist rotation!\n")
                        fflush(stdout)
                    }
                }
            }
        }

        // 7. Cleanup upon stream completion or signal cancellation & flush remaining stem clicks
        stemSource?.setStemPinchHandler(nil)
        if !shutdownState.isShuttingDown {
            for pinch in stemQueue.drain() {
                switch pinch {
                case .singlePinch:
                    await engine.injectStemClick(type: .leftClick(source: StemPinchType.singlePinch.rawValue))
                case .doublePinch:
                    await engine.injectStemClick(type: .rightClick(source: StemPinchType.doublePinch.rawValue))
                case .triplePinch:
                    await engine.recalibrate(quaternion: nil)
                }
            }
            _ = await engine.flushPendingStemClicks(sink: cursorSink)
        } else {
            _ = stemQueue.drain()
        }
        if let shutdownTask = shutdownState.takeShutdownTask() {
            await shutdownTask.value
        } else {
            await motionSource.stop()
        }
        signalTrap?.teardown()
        await audioWake.stopKeepAlive()
        if shutdownState.isShuttingDown {
            print("[AirPodWand] Clean shutdown complete. Restored audio output.")
        }
    }
}

/// Thread-safe FIFO queue buffering stem pinches for deterministic frame-ordered dispatch.
private final class StemEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StemPinchType] = []

    func enqueue(_ event: StemPinchType) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func drain() -> [StemPinchType] {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else { return [] }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }
}

/// Thread-safe state coordinating graceful signal shutdown.
private final class ShutdownState: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool = false
    private var shutdownTask: Task<Void, Never>?

    var isShuttingDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func triggerShutdownIfNeeded(_ makeTask: () -> Task<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        shutdownTask = makeTask()
        return true
    }

    func takeShutdownTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let task = shutdownTask
        shutdownTask = nil
        return task
    }
}
