//
//  HeadphoneMotionSource.swift
//  AirPodWandCore
//
//  Live CoreMotion Headphone Motion Pipeline (Requirement R4, Feature 17)
//  Streams 100 Hz 6-DoF MotionFrames from CMHeadphoneMotionManager
//

import Foundation
@preconcurrency import CoreMotion
import os
import simd

/// Errors produced during HeadphoneMotionSource initialization and streaming
public enum HeadphoneMotionError: Error, CustomStringConvertible, Sendable, Equatable {
    case motionPermissionDenied
    case motionPermissionRestricted
    case deviceMotionUnavailable
    case streamingAlreadyActive
    case underlyingError(String)

    public var description: String {
        switch self {
        case .motionPermissionDenied:
            return "Headphone motion permission denied by macOS TCC. Enable Motion permission in System Settings."
        case .motionPermissionRestricted:
            return "Headphone motion access is restricted by device policy or parental controls."
        case .deviceMotionUnavailable:
            return "Headphone device motion is unavailable. Ensure AirPods (AirPods 4 / Pro / Max) are connected and worn."
        case .streamingAlreadyActive:
            return "Headphone motion stream is already active."
        case .underlyingError(let message):
            return "CoreMotion error: \(message)"
        }
    }
}

/// Actor managing real-time CoreMotion headphone data acquisition conforming to MotionSourceProtocol.
public actor HeadphoneMotionSource: MotionSourceProtocol {
    private let motionManager: CMHeadphoneMotionManager
    private let queue: OperationQueue
    private let activeLock = OSAllocatedUnfairLock(initialState: false)
    private var streamContinuation: AsyncStream<MotionFrame>.Continuation?

    public init(motionManager: CMHeadphoneMotionManager = CMHeadphoneMotionManager()) {
        self.motionManager = motionManager
        let opQueue = OperationQueue()
        opQueue.name = "com.airpodwand.headphonemotion"
        opQueue.maxConcurrentOperationCount = 1
        opQueue.qualityOfService = .userInteractive
        self.queue = opQueue
    }

    /// Queries whether headphone device motion hardware is presently available.
    public var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }

    /// Queries whether the manager is actively streaming motion frames.
    public var isActive: Bool {
        activeLock.withLock { $0 }
    }

    /// Starts streaming 6-DoF MotionFrames at hardware cadence (~100 Hz).
    ///
    /// Executes defensive pre-flight authorization and availability checks to prevent
    /// macOS TCC aborts in unentitled or headless execution contexts.
    public func start() async throws -> AsyncStream<MotionFrame> {
        let alreadyActive = activeLock.withLock { $0 }
        guard !alreadyActive else {
            throw HeadphoneMotionError.streamingAlreadyActive
        }

        // 1. Pre-flight TCC authorization check
        let status = CMHeadphoneMotionManager.authorizationStatus()
        switch status {
        case .denied:
            throw HeadphoneMotionError.motionPermissionDenied
        case .restricted:
            throw HeadphoneMotionError.motionPermissionRestricted
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }

        // 2. Pre-flight hardware availability check
        guard motionManager.isDeviceMotionAvailable else {
            throw HeadphoneMotionError.deviceMotionUnavailable
        }

        // 3. Construct AsyncStream with backpressure buffering
        let (stream, continuation) = AsyncStream<MotionFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(50)
        )
        self.streamContinuation = continuation
        activeLock.withLock { $0 = true }

        let manager = self.motionManager
        let opQueue = self.queue
        let lock = self.activeLock
        continuation.onTermination = { [weak self] _ in
            lock.withLock { $0 = false }
            manager.stopDeviceMotionUpdates()
            opQueue.cancelAllOperations()
            Task { [weak self] in
                await self?.clearContinuation()
            }
        }

        // 4. Start CoreMotion headphone updates on serial background queue
        motionManager.startDeviceMotionUpdates(to: queue) { motion, error in
            if error != nil {
                continuation.finish()
                return
            }

            guard let motion = motion else { return }

            let frame = Self.mapDeviceMotion(motion)
            continuation.yield(frame)
        }

        return stream
    }

    /// Stops device motion updates and closes the active stream continuation.
    public func stop() async {
        let wasActive = activeLock.withLock { active -> Bool in
            guard active else { return false }
            active = false
            return true
        }
        if wasActive {
            motionManager.stopDeviceMotionUpdates()
            queue.cancelAllOperations()
        }
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func clearContinuation() {
        streamContinuation = nil
    }

    /// Maps a CoreMotion CMDeviceMotion instance to our domain MotionFrame.
    public static func mapDeviceMotion(_ motion: CMDeviceMotion) -> MotionFrame {
        let q = motion.attitude.quaternion
        let rot = motion.rotationRate
        let acc = motion.userAcceleration

        return MotionFrame(
            timestamp: motion.timestamp,
            attitudeQuaternion: simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w),
            rotationRate: simd_double3(x: rot.x, y: rot.y, z: rot.z),
            userAcceleration: simd_double3(x: acc.x, y: acc.y, z: acc.z)
        )
    }


}
