import Foundation

/// Abstract provider of 6-DoF motion frame streams.
public protocol MotionSourceProtocol: Sendable {
    /// Initiates motion data acquisition and returns an asynchronous stream of frames.
    func start() async throws -> AsyncStream<MotionFrame>
    
    /// Terminates motion data acquisition and releases internal resources.
    func stop() async
}
