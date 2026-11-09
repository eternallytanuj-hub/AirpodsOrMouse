import Foundation
import CoreGraphics

/// Defines a mouse click interaction detected by AirPodWand.
public enum ClickType: Sendable, Equatable {
    /// Left mouse button click with the triggering source identifier.
    /// Standard sources: "roll_twist_cw", "hover_dwell", "stem_single_pinch", "stem_pinch".
    case leftClick(source: String)
    
    /// Right mouse button click with the triggering source identifier.
    /// Standard sources: "roll_twist_ccw", "stem_double_pinch".
    case rightClick(source: String)
}

extension ClickType {
    /// The string identifier describing the gesture or input source.
    public var source: String {
        switch self {
        case .leftClick(let src): return src
        case .rightClick(let src): return src
        }
    }
    
    /// True if this click represents a left mouse button action.
    public var isLeftClick: Bool {
        if case .leftClick = self { return true }
        return false
    }
    
    /// True if this click represents a right mouse button action.
    public var isRightClick: Bool {
        if case .rightClick = self { return true }
        return false
    }
}

/// A timestamped, localized click event emitted by the gesture engines.
public struct ClickEvent: Sendable, Equatable {
    /// The classification and source of the click.
    public let type: ClickType
    
    /// Monotonic timestamp of the click event.
    public let timestamp: TimeInterval
    
    /// Screen coordinate where the click was emitted.
    public let screenPosition: CGPoint
    
    public init(type: ClickType, timestamp: TimeInterval, screenPosition: CGPoint = .zero) {
        self.type = type
        self.timestamp = timestamp
        self.screenPosition = screenPosition
    }
    
    /// Alias for screenPosition to match position-based access patterns.
    public var position: CGPoint {
        screenPosition
    }
    
    /// The triggering source identifier.
    public var source: String {
        type.source
    }
}
