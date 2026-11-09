import Foundation
import CoreGraphics

/// A structured record of a simulated click event captured by the event spy.
public struct RecordedClick: Sendable, Equatable {
    /// The click action and classification.
    public let type: ClickType
    
    /// Trigger source identifier.
    public let source: String
    
    /// Screen position where the click occurred.
    public let position: CGPoint
    
    /// Monotonic frame index in the simulation sequence.
    public let frameIndex: Int
    
    /// Monotonic timestamp of the event.
    public let timestamp: TimeInterval
    
    public init(
        type: ClickType,
        source: String,
        position: CGPoint,
        frameIndex: Int,
        timestamp: TimeInterval
    ) {
        self.type = type
        self.source = source
        self.position = position
        self.frameIndex = frameIndex
        self.timestamp = timestamp
    }
}

/// The authoritative evaluation outcome of a closed-loop synthetic simulation session.
public struct SimulationResult: Sendable, Equatable, CustomStringConvertible {
    /// Total number of motion frames evaluated.
    public let totalFrames: Int
    
    /// Total simulated session duration in seconds.
    public let duration: TimeInterval
    
    /// Total cumulative cursor distance traveled in screen points.
    public let totalDistance: Double
    
    /// Root mean square trajectory error in screen points against expected ground truth.
    public let trajectoryRmse: Double
    
    /// Parasitic vertical drift as a percentage of horizontal motion during pure yaw.
    public let crossAxisCouplingPercentage: Double
    
    /// Total count of all clicks dispatched.
    public let totalClicks: Int
    
    /// Complete array of recorded clicks with metadata.
    public let clicks: [RecordedClick]
    
    /// Maximum cursor displacement observed during a gesture lockout interval.
    public let maxLockedDelta: Double
    
    /// Alias for maxLockedDelta representing maximum cursor wander during lockouts.
    public var maxLockedWander: Double {
        maxLockedDelta
    }
    
    /// Boolean indicator whether the verification run passed all required invariants.
    public let passed: Bool
    
    /// Diagnostic descriptions for any invariant assertion failures.
    public let failureReasons: [String]
    
    public init(
        totalFrames: Int,
        duration: TimeInterval,
        totalDistance: Double,
        trajectoryRmse: Double,
        crossAxisCouplingPercentage: Double,
        totalClicks: Int,
        clicks: [RecordedClick],
        maxLockedDelta: Double,
        passed: Bool,
        failureReasons: [String] = []
    ) {
        self.totalFrames = totalFrames
        self.duration = duration
        self.totalDistance = totalDistance
        self.trajectoryRmse = trajectoryRmse
        self.crossAxisCouplingPercentage = crossAxisCouplingPercentage
        self.totalClicks = totalClicks
        self.clicks = clicks
        self.maxLockedDelta = maxLockedDelta
        self.passed = passed
        self.failureReasons = failureReasons
    }
    
    public var description: String {
        var lines: [String] = []
        lines.append("=== Closed-Loop Simulation Result ===")
        lines.append("Status:                     \(passed ? "PASSED" : "FAILED")")
        lines.append("Total Frames:               \(totalFrames)")
        lines.append("Duration:                   \(String(format: "%.2f", duration))s")
        lines.append("Total Distance Traveled:    \(String(format: "%.2f", totalDistance)) px")
        lines.append("Trajectory RMSE:            \(String(format: "%.3f", trajectoryRmse)) px (Limit: <= 3.5 px)")
        lines.append("Cross-Axis Coupling:        \(String(format: "%.2f", crossAxisCouplingPercentage))% (Limit: < 2.0%)")
        lines.append("Max Locked Delta:           \(String(format: "%.4f", maxLockedDelta)) px (Limit: == 0.0 px)")
        lines.append("Total Clicks:               \(totalClicks)")
        for click in clicks {
            lines.append("  • [t=\(String(format: "%.3f", click.timestamp))s, frame=\(click.frameIndex)] \(click.source) at (\(String(format: "%.1f", click.position.x)), \(String(format: "%.1f", click.position.y)))")
        }
        if !passed {
            lines.append("\nFailure Diagnostics:")
            for reason in failureReasons {
                lines.append("  [FAIL] \(reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
