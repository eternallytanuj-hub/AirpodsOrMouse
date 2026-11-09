//
//  SignalTrap.swift
//  AirPodWandCLI
//
//  POSIX Signal Trap for graceful termination and CoreAudio state restoration.
//

import Foundation
import Dispatch
import Darwin

/// Intercepts SIGINT and SIGTERM to execute clean shutdown of audio and motion pipelines.
public final class SignalTrap: @unchecked Sendable {
    private static let globalLock = NSLock()
    private static nonisolated(unsafe) var activeTrapCount: Int = 0

    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?
    private let queue = DispatchQueue(label: "com.airpodwand.signaltrap")
    private var isDisarmed: Bool = false
    private let lock = NSLock()

    public init(onSignal: @escaping @Sendable (Int32) -> Void) {
        Self.globalLock.lock()
        if Self.activeTrapCount == 0 {
            // Ignore default terminating action only on first active trap in process
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
        }
        Self.activeTrapCount += 1
        Self.globalLock.unlock()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        intSource.setEventHandler {
            onSignal(SIGINT)
        }
        intSource.resume()
        self.sigintSource = intSource

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        termSource.setEventHandler {
            onSignal(SIGTERM)
        }
        termSource.resume()
        self.sigtermSource = termSource
    }

    /// Disarms signal sources and restores default POSIX signal disposition when no traps remain active.
    public func teardown() {
        lock.lock()
        if isDisarmed {
            lock.unlock()
            return
        }
        isDisarmed = true

        sigintSource?.cancel()
        sigtermSource?.cancel()
        sigintSource = nil
        sigtermSource = nil
        lock.unlock()

        Self.globalLock.lock()
        if Self.activeTrapCount > 0 {
            Self.activeTrapCount -= 1
            if Self.activeTrapCount == 0 {
                signal(SIGINT, SIG_DFL)
                signal(SIGTERM, SIG_DFL)
            }
        }
        Self.globalLock.unlock()
    }

    deinit {
        teardown()
    }
}
