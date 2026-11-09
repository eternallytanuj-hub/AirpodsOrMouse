//
//  SoftwareAudioWake.swift
//  AirPodWandCore
//
//  Milestone 2: Audio Auto-Router, Keep-Alive Subsystem & Stem Media Command Hooks
//  Target: macOS 14+ / macOS 27+, Apple Silicon (arm64), Swift 6 Strict Concurrency
//  Zero external dependencies; 100% native Apple SDK frameworks.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MediaPlayer
import os

// MARK: - Audio Device Models

/// Hardware device information model for CoreAudio devices.
public struct AudioDeviceInfo: Sendable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let transportType: UInt32
    public let outputStreams: Int

    public init(id: AudioDeviceID, name: String, transportType: UInt32, outputStreams: Int) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.outputStreams = outputStreams
    }

    public init(id: AudioDeviceID, name: String, transportType: UInt32, outputStreamCount: Int) {
        self.init(id: id, name: name, transportType: transportType, outputStreams: outputStreamCount)
    }

    public var outputStreamCount: Int {
        outputStreams
    }

    /// Evaluates if transport matches Bluetooth Classic ('blue' = 0x626c7565) or Bluetooth LE ('blea' = 0x626c6561).
    public var isBluetooth: Bool {
        transportType == 0x626c7565 || transportType == 0x626c6561
    }

    /// Evaluates whether the device satisfies AirPods criteria:
    /// Bluetooth transport, name containing "AirPods", and output streams > 0.
    public var isAirPods: Bool {
        isBluetooth && name.localizedCaseInsensitiveContains("AirPods") && outputStreams > 0
    }

    /// Compatibility alias for test suites.
    public var isAirPodsCandidate: Bool {
        isAirPods
    }
}

/// Compatibility alias for AudioDeviceInfo.
public typealias AudioDeviceDescriptor = AudioDeviceInfo

/// Errors occurring during CoreAudio discovery, routing, or fallback operations.
public enum AudioRoutingError: Error, Sendable, Equatable {
    case airPodsNotFound
    case deviceHasNoOutput(AudioDeviceID)
    case invalidDeviceID(AudioDeviceID)
    case routingFailed(AudioDeviceID, OSStatus)
    case coreAudioFailure(OSStatus)
    case listenerRegistrationFailed(OSStatus)
}

// MARK: - Hardware Provider Abstraction & Production / Mock Providers

/// Abstraction for CoreAudio hardware operations, facilitating deterministic headless unit testing.
public protocol AudioHardwareProviding: Sendable {
    func getAudioDevices() -> [AudioDeviceInfo]
    func getDefaultOutputDevice() -> AudioDeviceID?
    func setDefaultOutputDevice(_ id: AudioDeviceID) -> OSStatus
    func addPropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    func removePropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

/// Production CoreAudio provider interacting directly with macOS AudioToolbox / CoreAudio C APIs.
public struct SystemAudioHardwareProvider: AudioHardwareProviding {
    public init() {}

    public func getAudioDevices() -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        )
        guard getStatus == noErr else { return [] }

        return ids.compactMap { id -> AudioDeviceInfo? in
            // 1. Query device name safely via Unmanaged<CFString>? to prevent pointer warnings under Swift 6
            var nameRef: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let nameStatus = withUnsafeMutablePointer(to: &nameRef) { ptr in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, ptr)
            }
            let name = (nameStatus == noErr ? nameRef?.takeRetainedValue() as String? : nil) ?? "Unknown Device"

            // 2. Query transport type ('blue', 'blea', 'bltn', 'virt', etc.)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)

            // 3. Query output stream count
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            _ = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
            let streams = Int(streamSize) / MemoryLayout<AudioStreamID>.size

            return AudioDeviceInfo(id: id, name: name, transportType: transport, outputStreams: streams)
        }
    }

    public func getDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultID
        )
        return (status == noErr && defaultID != 0) ? defaultID : nil
    }

    public func setDefaultOutputDevice(_ id: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var targetID = id
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &targetID
        )
    }

    public func addPropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var addr = address
        return AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            queue,
            listener
        )
    }

    public func removePropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var addr = address
        return AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            queue,
            listener
        )
    }
}

/// Thread-safe in-memory mock provider for testing CoreAudio discovery, routing, and listeners without hardware.
public final class MockAudioHardwareProvider: AudioHardwareProviding, @unchecked Sendable {
    private struct ListenerIdentity: Equatable, Sendable {
        let bytes: [UInt8]

        init(_ block: @escaping AudioObjectPropertyListenerBlock) {
            // Wrap in concrete non-generic ListenerBox before reading bytes so Swift
            // does not emit a fresh per-call generic reabstraction thunk.
            let box = ListenerBox(block: block)
            self.bytes = withUnsafeBytes(of: box) { Array($0) }
        }
    }

    private struct ListenerRecord: @unchecked Sendable {
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
        let identity: ListenerIdentity
    }

    private struct State: @unchecked Sendable {
        var devices: [AudioDeviceInfo]
        var defaultOutputDevice: AudioDeviceID?
        var listeners: [AudioObjectPropertySelector: [ListenerRecord]]
    }

    private let stateLock: OSAllocatedUnfairLock<State>

    public init(
        devices: [AudioDeviceInfo] = [],
        defaultOutputDevice: AudioDeviceID? = nil
    ) {
        self.stateLock = OSAllocatedUnfairLock(initialState: State(
            devices: devices,
            defaultOutputDevice: defaultOutputDevice,
            listeners: [:]
        ))
    }

    public func getAudioDevices() -> [AudioDeviceInfo] {
        stateLock.withLock { $0.devices }
    }

    public func getDefaultOutputDevice() -> AudioDeviceID? {
        stateLock.withLock { $0.defaultOutputDevice }
    }

    public func setDefaultOutputDevice(_ id: AudioDeviceID) -> OSStatus {
        let (success, records) = stateLock.withLock { state -> (Bool, [ListenerRecord]) in
            guard id != 0 else { return (false, []) }
            guard state.devices.contains(where: { $0.id == id }) else { return (false, []) }
            state.defaultOutputDevice = id
            let listeners = state.listeners[kAudioHardwarePropertyDefaultOutputDevice] ?? []
            return (true, listeners)
        }
        guard success else { return -1 }

        for record in records {
            record.queue.async {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                record.block(1, &addr)
            }
        }
        return noErr
    }

    public func addPropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let identity = ListenerIdentity(listener)
        let record = ListenerRecord(queue: queue, block: listener, identity: identity)
        stateLock.withLock { state in
            var list = state.listeners[address.mSelector] ?? []
            list.append(record)
            state.listeners[address.mSelector] = list
        }
        return noErr
    }

    public func removePropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        let targetIdentity = ListenerIdentity(listener)
        stateLock.withLock { state in
            guard var list = state.listeners[address.mSelector] else { return }
            list.removeAll { record in
                record.queue === queue && record.identity == targetIdentity
            }
            state.listeners[address.mSelector] = list.isEmpty ? nil : list
        }
        return noErr
    }

    /// Mutates the active device collection and fires device change listeners asynchronously.
    public func setDevices(_ newDevices: [AudioDeviceInfo]) {
        let records = stateLock.withLock { state -> [ListenerRecord] in
            state.devices = newDevices
            return state.listeners[kAudioHardwarePropertyDevices] ?? []
        }
        for record in records {
            record.queue.async {
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                record.block(1, &addr)
            }
        }
    }
}

// MARK: - Internal Sendable Box

/// Unchecked box holding C AudioObjectPropertyListenerBlock to satisfy Swift 6 Sendable constraints.
private struct ListenerBox: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock
}

// MARK: - AudioAutoRouter

/// CoreAudio Device Discovery, Routing, and Disconnect Fallback Subsystem.
public final class AudioAutoRouter: @unchecked Sendable {
    public let provider: AudioHardwareProviding
    private let queue = DispatchQueue(label: "com.airpodwand.coreaudio.router", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    private struct State: Sendable {
        var previousDefaultDeviceID: AudioDeviceID?
        var activeAirPodsDeviceID: AudioDeviceID?
        var isMonitoring: Bool = false
        var devicesListener: ListenerBox?
        var defaultListener: ListenerBox?
        var onDisconnect: (@Sendable () -> Void)?
        var onReconnect: (@Sendable (AudioDeviceID) -> Void)?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    public init(provider: AudioHardwareProviding = SystemAudioHardwareProvider()) {
        self.provider = provider
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stopMonitoring()
    }

    /// Discovers connected AirPods candidate meeting all physical and stream constraints.
    public func discoverAirPods() -> AudioDeviceInfo? {
        let devices = provider.getAudioDevices()
        return devices.first(where: { $0.isAirPods })
    }

    /// Programmatically discovers connected AirPods, captures current default device for fallback,
    /// and sets AirPods as default system output device.
    /// Returns .failure(.airPodsNotFound) gracefully without throwing or crashing if absent.
    public func discoverAndRouteAirPods() -> Result<AudioDeviceID, AudioRoutingError> {
        let currentDefault = provider.getDefaultOutputDevice()
        lock.withLock { state in
            if state.previousDefaultDeviceID == nil {
                state.previousDefaultDeviceID = currentDefault
            }
        }

        guard let airPods = discoverAirPods() else {
            return .failure(.airPodsNotFound)
        }

        guard airPods.outputStreams > 0 else {
            return .failure(.deviceHasNoOutput(airPods.id))
        }

        // Validate candidate exists before routing
        let allDevices = provider.getAudioDevices()
        guard allDevices.contains(where: { $0.id == airPods.id }) else {
            return .failure(.invalidDeviceID(airPods.id))
        }

        let status = provider.setDefaultOutputDevice(airPods.id)
        guard status == noErr else {
            return .failure(.routingFailed(airPods.id, status))
        }

        // Post-check verification against silent ignore quirk
        if let newDefault = provider.getDefaultOutputDevice(), newDefault != airPods.id {
            return .failure(.routingFailed(airPods.id, -1))
        }

        lock.withLock { state in
            state.activeAirPodsDeviceID = airPods.id
        }
        return .success(airPods.id)
    }

    /// Gracefully falls back to system default output device without throwing exceptions or crashing.
    @discardableResult
    public func fallbackToDefaultOutput() -> Result<AudioDeviceID, AudioRoutingError> {
        let fallbackTarget: AudioDeviceID? = lock.withLock { state in
            state.previousDefaultDeviceID
        }

        let targetID: AudioDeviceID
        let currentDevices = provider.getAudioDevices()
        if let id = fallbackTarget, currentDevices.contains(where: { $0.id == id }) {
            targetID = id
        } else if let current = provider.getDefaultOutputDevice(), currentDevices.contains(where: { $0.id == current && $0.outputStreams > 0 }) {
            targetID = current
        } else if let firstOutput = currentDevices.first(where: { $0.outputStreams > 0 }) {
            targetID = firstOutput.id
        } else {
            return .failure(.airPodsNotFound)
        }

        let status = provider.setDefaultOutputDevice(targetID)
        guard status == noErr else {
            return .failure(.routingFailed(targetID, status))
        }

        lock.withLock { state in
            state.activeAirPodsDeviceID = nil
        }
        return .success(targetID)
    }

    /// Indicates whether AirPods are currently connected, routed, and valid.
    public var isAirPodsActive: Bool {
        lock.withLock { state in
            guard let activeID = state.activeAirPodsDeviceID else { return false }
            return provider.getAudioDevices().contains(where: { $0.id == activeID && $0.isAirPods })
        }
    }

    /// Returns the currently active AirPods device ID if connected.
    public var activeAirPodsDeviceID: AudioDeviceID? {
        lock.withLock { $0.activeAirPodsDeviceID }
    }

    /// Returns previous default device ID prior to routing.
    public var previousDefaultDeviceID: AudioDeviceID? {
        lock.withLock { $0.previousDefaultDeviceID }
    }

    /// Starts monitoring CoreAudio hardware events for physical disconnects and re-routes safely.
    public func startMonitoring(
        onDisconnect: (@Sendable () -> Void)? = nil,
        onReconnect: (@Sendable (AudioDeviceID) -> Void)? = nil
    ) {
        let shouldStart: Bool = lock.withLock { state in
            if state.isMonitoring { return false }
            state.isMonitoring = true
            state.onDisconnect = onDisconnect
            state.onReconnect = onReconnect
            return true
        }
        guard shouldStart else { return }

        // 1. Devices property address
        let devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleHardwareDevicesChanged()
        }

        // 2. Default output device property address
        let defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputDeviceChanged()
        }

        let devBox = ListenerBox(block: devicesBlock)
        let defBox = ListenerBox(block: defaultBlock)

        lock.withLock { state in
            state.devicesListener = devBox
            state.defaultListener = defBox
        }

        _ = provider.addPropertyListener(address: devicesAddr, queue: queue, listener: devicesBlock)
        _ = provider.addPropertyListener(address: defaultAddr, queue: queue, listener: defaultBlock)
    }

    /// Stops monitoring CoreAudio hardware events and unregisters listener blocks.
    public func stopMonitoring() {
        let (devicesBox, defaultBox, wasMonitoring): (ListenerBox?, ListenerBox?, Bool) = lock.withLock { state in
            guard state.isMonitoring else { return (nil, nil, false) }
            state.isMonitoring = false
            state.activeAirPodsDeviceID = nil
            let dev = state.devicesListener
            let def = state.defaultListener
            state.devicesListener = nil
            state.defaultListener = nil
            state.onDisconnect = nil
            state.onReconnect = nil
            return (dev, def, true)
        }

        guard wasMonitoring else { return }

        let devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        if let devBox = devicesBox {
            _ = provider.removePropertyListener(address: devicesAddr, queue: queue, listener: devBox.block)
        }
        if let defBox = defaultBox {
            _ = provider.removePropertyListener(address: defaultAddr, queue: queue, listener: defBox.block)
        }

        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
    }

    private func handleHardwareDevicesChanged() {
        guard lock.withLock({ $0.isMonitoring }) else { return }

        let currentActiveID = lock.withLock { $0.activeAirPodsDeviceID }
        let devices = provider.getAudioDevices()

        if let activeID = currentActiveID {
            let stillConnected = devices.contains(where: { $0.id == activeID && $0.isAirPods })
            if !stillConnected {
                // AirPods disconnected! Fall back gracefully.
                guard lock.withLock({ $0.isMonitoring }) else { return }
                _ = fallbackToDefaultOutput()
                let callback = lock.withLock { state -> (@Sendable () -> Void)? in
                    guard state.isMonitoring else { return nil }
                    return state.onDisconnect
                }
                callback?()
            }
        } else {
            // Was previously disconnected; check if AirPods reconnected
            if devices.contains(where: { $0.isAirPods }) {
                guard lock.withLock({ $0.isMonitoring }) else { return }
                let routeResult = discoverAndRouteAirPods()
                if case .success(let routedID) = routeResult {
                    let callback = lock.withLock { state -> (@Sendable (AudioDeviceID) -> Void)? in
                        guard state.isMonitoring else { return nil }
                        return state.onReconnect
                    }
                    callback?(routedID)
                }
            }
        }
    }

    private func handleDefaultOutputDeviceChanged() {
        guard lock.withLock({ $0.isMonitoring }) else { return }
        let currentDefault = provider.getDefaultOutputDevice()
        lock.withLock { state in
            guard state.isMonitoring else { return }
            if let activeID = state.activeAirPodsDeviceID, let cur = currentDefault, cur != activeID {
                // Detected system or user switch away from AirPods
            }
        }
    }
}

// MARK: - Keep-Alive Buffer Synthesizer

/// Algorithmic helper for sub-audible keep-alive buffer synthesis and mathematical verification.
public enum AudioBufferSynthesizer: Sendable {
    public static func synthesize(
        sampleRate: Double = 44100.0,
        frequencyHz: Double = 20.0,
        amplitude: Double = 0.001,
        frameCount: Int = 1024,
        startingPhase: Double = 0.0
    ) -> (samples: [Float], finalPhase: Double) {
        guard frameCount > 0 else { return ([], startingPhase) }

        // Parameter boundary guards against zero, negative, NaN, and Infinite inputs
        guard sampleRate > 0.0, sampleRate.isFinite,
              frequencyHz >= 0.0, frequencyHz.isFinite,
              amplitude.isFinite,
              startingPhase.isFinite else {
            return ([], startingPhase.isFinite ? startingPhase : 0.0)
        }

        let twoPi = 2.0 * Double.pi

        // Normalize startingPhase strictly within [0, 2π)
        var phase = startingPhase.truncatingRemainder(dividingBy: twoPi)
        if phase < 0.0 {
            phase += twoPi
        }

        var samples = [Float]()
        samples.reserveCapacity(frameCount)
        let phaseInc = (twoPi * frequencyHz) / sampleRate
        guard phaseInc.isFinite else {
            return ([], phase)
        }
        let stepInc = phaseInc.truncatingRemainder(dividingBy: twoPi)

        for _ in 0..<frameCount {
            let sample = Float(amplitude * sin(phase))
            samples.append(sample)
            phase += stepInc
            if phase >= twoPi {
                phase -= twoPi
            }
        }
        return (samples, phase)
    }

    public static func synthesizeKeepAliveBuffer(
        sampleRate: Double = 44100.0,
        frequencyHz: Double = 20.0,
        amplitude: Double = 0.001,
        frameCount: Int = 1024,
        startingPhase: Double = 0.0
    ) -> (samples: [Float], finalPhase: Double) {
        synthesize(
            sampleRate: sampleRate,
            frequencyHz: frequencyHz,
            amplitude: amplitude,
            frameCount: frameCount,
            startingPhase: startingPhase
        )
    }

    public static func calculateRMS(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0.0 }
        let sumSquares = samples.reduce(0.0) { sum, s in
            let val = Double(s)
            return val.isFinite ? sum + (val * val) : sum
        }
        let meanSquare = sumSquares / Double(samples.count)
        guard meanSquare > 0.0, meanSquare.isFinite else { return 0.0 }
        return sqrt(meanSquare)
    }

    public static func calculateDBFS(rms: Double) -> Double {
        guard rms > 0.0, rms.isFinite else { return -100.0 }
        let db = 20.0 * log10(rms)
        return db.isFinite ? db : -100.0
    }
}

public typealias KeepAliveBufferSynthesizer = AudioBufferSynthesizer

// MARK: - Real-Time Tone Generator State

/// Thread-safe real-time state holder for allocation-free inaudible tone synthesis.
public final class ToneGeneratorState: Sendable {
    private struct Storage: Sendable {
        var phase: Double
        var frequency: Double
        var sampleRate: Double
        var amplitude: Float
    }

    private let lock: OSAllocatedUnfairLock<Storage>

    public var phase: Double {
        get { lock.withLock { $0.phase } }
        set {
            let sanitized = newValue.isFinite ? newValue : 0.0
            lock.withLock { $0.phase = sanitized }
        }
    }

    public var frequency: Double {
        get { lock.withLock { $0.frequency } }
        set {
            let sanitized = (newValue.isFinite && newValue >= 0.0) ? newValue : 20.0
            lock.withLock { $0.frequency = sanitized }
        }
    }

    public var sampleRate: Double {
        get { lock.withLock { $0.sampleRate } }
        set {
            let sanitized = (newValue.isFinite && newValue > 0.0) ? newValue : 48000.0
            lock.withLock { $0.sampleRate = sanitized }
        }
    }

    public var amplitude: Float {
        get { lock.withLock { $0.amplitude } }
        set {
            let sanitized = newValue.isFinite ? newValue : 0.001
            lock.withLock { $0.amplitude = sanitized }
        }
    }

    public init(
        frequency: Double = 20.0,
        sampleRate: Double = 48000.0,
        amplitude: Float = 0.001
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: Storage(
            phase: 0.0,
            frequency: (frequency.isFinite && frequency >= 0.0) ? frequency : 20.0,
            sampleRate: (sampleRate.isFinite && sampleRate > 0.0) ? sampleRate : 48000.0,
            amplitude: amplitude.isFinite ? amplitude : 0.001
        ))
    }
}

// MARK: - SoftwareAudioWake Primary Class

/// Software audio wake and keep-alive subsystem conforming to `AudioWakeProtocol` and `StemPinchHandling`.
public final class SoftwareAudioWake: AudioWakeProtocol, StemPinchHandling, Sendable {

    public struct Config: Sendable {
        public var frequencyHz: Double
        public var amplitude: Double
        public var sampleRate: Double

        public init(
            frequencyHz: Double = 20.0,
            amplitude: Double = 0.001,
            sampleRate: Double = 44100.0
        ) {
            self.frequencyHz = frequencyHz
            self.amplitude = amplitude
            self.sampleRate = sampleRate
        }
    }

    private struct State: Sendable {
        var isRunning: Bool = false
        var isAirPodsActive: Bool = false
        var isNowPlayingActive: Bool = false
    }

    private struct CommandRegistration: @unchecked Sendable {
        let command: MPRemoteCommand
        let token: Any
    }

    private struct StemPinchHandlerBox: Sendable {
        let handler: (@Sendable (StemPinchType) -> Void)?
    }

    /// Per-node isolated render phase state preventing cross-restart render callback races.
    private final class RenderPhaseBox: @unchecked Sendable {
        var phase: Double = 0.0
    }

    public let config: Config
    public let router: AudioAutoRouter
    private let toneState: ToneGeneratorState

    private let lifecycleLock = NSLock()
    private let engineOpLock = NSLock()
    private let stateLock: OSAllocatedUnfairLock<State>
    private let engineLock: OSAllocatedUnfairLock<AVAudioEngine?>
    private let sourceNodeLock: OSAllocatedUnfairLock<AVAudioSourceNode?>
    private let commandTokensLock: OSAllocatedUnfairLock<[CommandRegistration]>
    private let pinchHandlerLock: OSAllocatedUnfairLock<StemPinchHandlerBox>
    private static let mediaCenterLock = NSLock()
    private static nonisolated(unsafe) var activeMediaClients: Int = 0
    private let mediaRegisteredLock = OSAllocatedUnfairLock(initialState: false)

    public init(
        config: Config = Config(),
        hardwareProvider: AudioHardwareProviding = SystemAudioHardwareProvider(),
        onStemPinch: (@Sendable (StemPinchType) -> Void)? = nil
    ) {
        self.config = config
        self.router = AudioAutoRouter(provider: hardwareProvider)
        self.toneState = ToneGeneratorState(
            frequency: config.frequencyHz,
            sampleRate: config.sampleRate,
            amplitude: Float(config.amplitude)
        )
        self.stateLock = OSAllocatedUnfairLock(initialState: State())
        self.engineLock = OSAllocatedUnfairLock(initialState: nil)
        self.sourceNodeLock = OSAllocatedUnfairLock(initialState: nil)
        self.commandTokensLock = OSAllocatedUnfairLock(initialState: [])
        self.pinchHandlerLock = OSAllocatedUnfairLock(initialState: StemPinchHandlerBox(handler: onStemPinch))
    }

    public convenience init(onStemPinch: @escaping @Sendable (StemPinchType) -> Void) {
        self.init(config: Config(), hardwareProvider: SystemAudioHardwareProvider(), onStemPinch: onStemPinch)
    }

    deinit {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.withLock { state in
            state.isRunning = false
            state.isAirPodsActive = false
            state.isNowPlayingActive = false
        }
        router.stopMonitoring()
        stopAudioEngine()
        clearNowPlayingInfo()
        unbindStemCommands()
    }

    // MARK: - AudioWakeProtocol Properties

    public var isAirPodsActive: Bool {
        stateLock.withLock { $0.isAirPodsActive }
    }

    public var isRunning: Bool {
        stateLock.withLock { $0.isRunning }
    }

    public var isNowPlayingActive: Bool {
        stateLock.withLock { $0.isNowPlayingActive }
    }

    // MARK: - Stem Pinch Command Handling

    public func setStemPinchHandler(_ handler: (@Sendable (StemPinchType) -> Void)?) {
        pinchHandlerLock.withLock { $0 = StemPinchHandlerBox(handler: handler) }
    }

    /// Invokes stem command logic and returns MPRemoteCommandHandlerStatus.success (0) for macOS.
    @discardableResult
    public func handleStemCommand(for type: StemPinchType) -> MPRemoteCommandHandlerStatus {
        let handler = pinchHandlerLock.withLock { $0.handler }
        handler?(type)
        return .success
    }

    // MARK: - AudioWakeProtocol Methods

    public func startKeepAlive() async throws {
        _startKeepAliveSync()
    }

    public func stopKeepAlive() async {
        _stopKeepAliveSync()
    }

    private func _startKeepAliveSync() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let alreadyRunning = stateLock.withLock { state -> Bool in
            if state.isRunning { return true }
            state.isRunning = true
            return false
        }
        if alreadyRunning { return }

        // 1. Discover and route AirPods; fallback gracefully if absent
        let routeResult = router.discoverAndRouteAirPods()
        let targetDeviceID: AudioDeviceID?
        let isAirPods: Bool

        switch routeResult {
        case .success(let devID):
            targetDeviceID = devID
            isAirPods = true
        case .failure:
            targetDeviceID = router.provider.getDefaultOutputDevice()
            isAirPods = false
        }

        stateLock.withLock { state in
            if state.isRunning {
                state.isAirPodsActive = isAirPods
            }
        }

        // 2. Ensure clean state, then start AVAudioEngine with 20 Hz keep-alive tone
        stopAudioEngine()
        startAudioEngine(targetDeviceID: targetDeviceID)

        // 3. Register Now Playing Info & bind stem commands before starting topology callbacks
        registerNowPlayingInfo()
        bindStemCommands()

        // 4. Start hardware topology monitoring
        router.startMonitoring(
            onDisconnect: { [weak self] in
                self?.handleAirPodsDisconnected()
            },
            onReconnect: { [weak self] newDevID in
                self?.handleAirPodsReconnected(newDevID)
            }
        )
    }

    private func _stopKeepAliveSync() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let wasRunning = stateLock.withLock { state -> Bool in
            guard state.isRunning else { return false }
            state.isRunning = false
            state.isAirPodsActive = false
            state.isNowPlayingActive = false
            return true
        }
        guard wasRunning else { return }

        // 1. Stop CoreAudio monitoring first to prevent new hardware events
        router.stopMonitoring()

        // 2. Stop audio engine
        stopAudioEngine()

        // 3. Clear Now Playing Info (updates active client refcount)
        clearNowPlayingInfo()

        // 4. Unbind MPRemoteCommandCenter
        unbindStemCommands()

        // 5. Restore original default output device
        _ = router.fallbackToDefaultOutput()
    }

    // MARK: - CoreAudio Forwarding Helpers

    public func discoverAirPodsDevice() -> AudioDeviceID? {
        router.discoverAirPods()?.id
    }

    public func isDeviceAirPods(_ devID: AudioDeviceID) -> Bool {
        router.provider.getAudioDevices().contains(where: { $0.id == devID && $0.isAirPods })
    }

    public func getSystemDefaultOutputDevice() -> AudioDeviceID? {
        router.provider.getDefaultOutputDevice()
    }

    public func setSystemDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        router.provider.setDefaultOutputDevice(deviceID) == noErr
    }

    // MARK: - Internal Disconnect / Reconnect Callbacks

    private func handleAirPodsDisconnected() {
        stateLock.withLock { state in
            guard state.isRunning else { return }
            state.isAirPodsActive = false
        }
    }

    private func handleAirPodsReconnected(_ devID: AudioDeviceID) {
        let shouldBind = stateLock.withLock { state -> Bool in
            guard state.isRunning else { return false }
            state.isAirPodsActive = true
            return true
        }
        guard shouldBind else { return }
        // Bind output node to reconnected device
        bindOutputNodeToDevice(devID)
    }

    // MARK: - AVFoundation Keep-Alive Engine

    private func startAudioEngine(targetDeviceID: AudioDeviceID?) {
        let engine = AVAudioEngine()
        let freq = toneState.frequency
        let sampleRate = toneState.sampleRate
        let amp = toneState.amplitude
        let phaseBox = RenderPhaseBox()

        let sourceNode = AVAudioSourceNode { isSilence, _, frameCount, outputData -> OSStatus in
            isSilence.pointee = ObjCBool(false)

            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            let twoPi = 2.0 * Double.pi
            var p = phaseBox.phase
            let rawInc = (twoPi * freq) / sampleRate
            let stepInc = rawInc.isFinite ? rawInc.truncatingRemainder(dividingBy: twoPi) : 0.0
            let frames = Int(frameCount)

            for frame in 0..<frames {
                let sample = Float(sin(p)) * amp
                p += stepInc
                if p >= twoPi {
                    p -= twoPi
                }

                for buffer in abl {
                    guard let mData = buffer.mData else { continue }
                    let ptr = mData.assumingMemoryBound(to: Float.self)
                    let channels = Int(buffer.mNumberChannels)
                    if channels == 1 {
                        ptr[frame] = sample
                    } else {
                        for ch in 0..<channels {
                            ptr[frame * channels + ch] = sample
                        }
                    }
                }
            }
            phaseBox.phase = p
            return noErr
        }

        engine.attach(sourceNode)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return
        }

        do {
            // Modern non-deprecated macOS 27 node connection:
            if #available(macOS 27.0, *) {
                try engine.connectNode(sourceNode, to: engine.mainMixerNode, format: format)
            } else {
                engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
            }

            // Modern non-deprecated macOS 27 AudioUnit binding:
            if let deviceID = targetDeviceID {
                var devID = deviceID
                let size = UInt32(MemoryLayout<AudioDeviceID>.size)
                if #available(macOS 27.0, *) {
                    _ = engine.outputNode.withAudioUnit { unit -> OSStatus in
                        guard let unit = unit else { return -1 }
                        return AudioUnitSetProperty(
                            unit,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &devID,
                            size
                        )
                    }
                } else {
                    if let unit = engine.outputNode.audioUnit {
                        _ = AudioUnitSetProperty(
                            unit,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &devID,
                            size
                        )
                    }
                }
            }

            try engine.start()
            engineLock.withLock { $0 = engine }
            sourceNodeLock.withLock { $0 = sourceNode }
        } catch {
            // Engine start failure caught cleanly without crashing
        }
    }

    private func bindOutputNodeToDevice(_ deviceID: AudioDeviceID) {
        engineOpLock.lock()
        defer { engineOpLock.unlock() }

        let engine = engineLock.withLock { $0 }
        guard let engine = engine else { return }

        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if #available(macOS 27.0, *) {
            _ = engine.outputNode.withAudioUnit { unit -> OSStatus in
                guard let unit = unit else { return -1 }
                return AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    size
                )
            }
        } else {
            if let unit = engine.outputNode.audioUnit {
                _ = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    size
                )
            }
        }
    }

    private func stopAudioEngine() {
        engineOpLock.lock()
        defer { engineOpLock.unlock() }

        let engine = engineLock.withLock { engine -> AVAudioEngine? in
            let copy = engine
            engine = nil
            return copy
        }
        let sourceNode = sourceNodeLock.withLock { node -> AVAudioSourceNode? in
            let copy = node
            node = nil
            return copy
        }
        if let engine = engine {
            // Stop engine first to immediately halt real-time render thread
            engine.stop()
            if let sourceNode = sourceNode {
                engine.disconnectNodeOutput(sourceNode)
                engine.detach(sourceNode)
            }
            engine.reset()
        }
    }

    // MARK: - MediaPlayer Now Playing & Stem Command Center

    /// Constructs the Now Playing metadata dictionary keeping H2 telemetry active.
    public static func buildNowPlayingInfo() -> [String: Any] {
        [
            MPMediaItemPropertyTitle: "AirPodWand Keep-Alive",
            MPMediaItemPropertyArtist: "AirPodWand Driver",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
        ]
    }

    private func registerNowPlayingInfo() {
        let shouldIncrement = mediaRegisteredLock.withLock { registered -> Bool in
            guard !registered else { return false }
            registered = true
            return true
        }
        Self.mediaCenterLock.lock()
        if shouldIncrement {
            Self.activeMediaClients += 1
        }
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .playing
        center.nowPlayingInfo = Self.buildNowPlayingInfo()
        Self.mediaCenterLock.unlock()
        stateLock.withLock { $0.isNowPlayingActive = true }
    }

    private func clearNowPlayingInfo() {
        let shouldDecrement = mediaRegisteredLock.withLock { registered -> Bool in
            guard registered else { return false }
            registered = false
            return true
        }
        Self.mediaCenterLock.lock()
        if shouldDecrement {
            Self.activeMediaClients = max(0, Self.activeMediaClients - 1)
        }
        if Self.activeMediaClients == 0 {
            let center = MPNowPlayingInfoCenter.default()
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
        Self.mediaCenterLock.unlock()
        stateLock.withLock { $0.isNowPlayingActive = false }
    }

    private func bindStemCommands() {
        Self.mediaCenterLock.lock()
        defer { Self.mediaCenterLock.unlock() }

        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.isEnabled = true
        let t1 = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleStemCommand(for: .singlePinch) ?? .commandFailed
        }

        center.nextTrackCommand.isEnabled = true
        let t2 = center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleStemCommand(for: .doublePinch) ?? .commandFailed
        }

        center.previousTrackCommand.isEnabled = true
        let t3 = center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleStemCommand(for: .triplePinch) ?? .commandFailed
        }

        let registrations = [
            CommandRegistration(command: center.togglePlayPauseCommand, token: t1),
            CommandRegistration(command: center.nextTrackCommand, token: t2),
            CommandRegistration(command: center.previousTrackCommand, token: t3)
        ]
        commandTokensLock.withLock { $0 = registrations }
    }

    private func unbindStemCommands() {
        let registrations = commandTokensLock.withLock { tokens -> [CommandRegistration] in
            let copy = tokens
            tokens.removeAll()
            return copy
        }
        Self.mediaCenterLock.lock()
        defer { Self.mediaCenterLock.unlock() }

        let noOtherClients = (Self.activeMediaClients == 0)
        for reg in registrations {
            reg.command.removeTarget(reg.token)
            if noOtherClients {
                reg.command.isEnabled = false
            }
        }
    }
}
