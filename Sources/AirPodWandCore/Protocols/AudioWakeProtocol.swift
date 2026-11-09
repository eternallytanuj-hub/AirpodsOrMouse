import Foundation

/// Stem media pinching gesture types emitted by AirPods 4 force sensor stems.
public enum StemPinchType: String, Sendable, CaseIterable {
    case singlePinch = "stem_single_pinch"
    case doublePinch = "stem_double_pinch"
    case triplePinch = "stem_triple_pinch"
}

/// Controls Bluetooth audio keep-alive streaming and CoreAudio device routing.
public protocol AudioWakeProtocol: Sendable {
    /// Discovers connected AirPods, configures default audio routing, and starts the keep-alive tone.
    func startKeepAlive() async throws
    
    /// Halts keep-alive streaming and unregisters media hooks.
    func stopKeepAlive() async
    
    /// Indicates whether AirPods are currently connected, routed, and actively receiving audio.
    var isAirPodsActive: Bool { get }
}

/// Optional capability protocol for audio subsystems that surface AirPods stem media pinch gestures.
public protocol StemPinchHandling: Sendable {
    /// Registers or clears the callback invoked when a stem pinch command is received.
    func setStemPinchHandler(_ handler: (@Sendable (StemPinchType) -> Void)?)
}
