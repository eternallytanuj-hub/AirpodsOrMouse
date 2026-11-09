import Foundation

/// Destination sink for cursor displacements and click events.
public protocol CursorEventSink: Sendable {
    /// Dispatches a relative cursor displacement.
    func postMove(delta: CursorDelta) async
    
    /// Dispatches a mouse button click.
    func postClick(type: ClickType) async
}
