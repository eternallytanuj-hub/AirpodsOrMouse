import Foundation

/// Represents a relative 2D cursor displacement dispatched to the cursor sink.
public struct CursorDelta: Sendable, Equatable {
    /// Horizontal displacement in screen points (positive = right).
    public let dx: Double
    
    /// Vertical displacement in screen points (positive = down in macOS display coordinates).
    public let dy: Double
    
    /// Indicates whether cursor motion is frozen by a gesture lock (e.g. during roll-twist gesture execution).
    public let isLocked: Bool
    
    /// Monotonic timestamp of the displacement frame.
    public let timestamp: TimeInterval
    
    public init(dx: Double, dy: Double, isLocked: Bool = false, timestamp: TimeInterval = 0) {
        self.dx = dx
        self.dy = dy
        self.isLocked = isLocked
        self.timestamp = timestamp
    }
    
    /// Standard zero displacement delta.
    public static let zero = CursorDelta(dx: 0.0, dy: 0.0, isLocked: false, timestamp: 0)
    
    /// Locked zero displacement delta used during gesture lockouts.
    public static let locked = CursorDelta(dx: 0.0, dy: 0.0, isLocked: true, timestamp: 0)
}
