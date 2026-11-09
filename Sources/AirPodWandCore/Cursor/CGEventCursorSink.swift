//
//  CGEventCursorSink.swift
//  AirPodWandCore
//
//  Production-grade CoreGraphics System Cursor Injection Sink (Requirement R4, Feature 18)
//  Translates CursorDelta and ClickType into macOS WindowServer cursor movements and clicks.
//

import Foundation
import CoreGraphics
import ApplicationServices

/// Configuration for CGEventCursorSink controlling display bounds, injection taps, and dry-run mode.
public struct CGEventCursorSinkConfiguration: Sendable, Equatable {
    /// Initial cursor position. If nil, defaults to current system cursor position or center of active display.
    public var initialPosition: CGPoint?
    /// Fallback display bounds used when headless or when display bounds query returns invalid geometry.
    public var fallbackDisplayBounds: CGRect
    /// Custom display bounds override.
    public var customDisplayBounds: CGRect?
    /// Quartz event tap insertion point (default: .cghidEventTap).
    public var tapLocation: CGEventTapLocation
    /// If false, suppresses CGEvent generation and posting (used for headless/safe testing).
    public var isEventPostingEnabled: Bool
    /// If false, suppresses CGWarpMouseCursorPosition (used for headless/safe testing).
    public var isWarpCursorEnabled: Bool
    /// Optional hold delay between down and up events for clicks in live mode.
    public var clickHoldDuration: TimeInterval
    /// Maximum number of recent ClickEvent records retained in memory.
    public var maxClickHistory: Int

    public init(
        initialPosition: CGPoint? = nil,
        fallbackDisplayBounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        customDisplayBounds: CGRect? = nil,
        tapLocation: CGEventTapLocation = .cghidEventTap,
        isEventPostingEnabled: Bool = true,
        isWarpCursorEnabled: Bool = true,
        clickHoldDuration: TimeInterval = 0.0,
        maxClickHistory: Int = 100
    ) {
        self.initialPosition = initialPosition
        self.fallbackDisplayBounds = fallbackDisplayBounds
        self.customDisplayBounds = customDisplayBounds
        self.tapLocation = tapLocation
        self.isEventPostingEnabled = isEventPostingEnabled
        self.isWarpCursorEnabled = isWarpCursorEnabled
        self.clickHoldDuration = clickHoldDuration
        self.maxClickHistory = maxClickHistory
    }
}

/// Swift 6 Actor conforming to CursorEventSink that dispatches moves and clicks to macOS WindowServer.
public actor CGEventCursorSink: CursorEventSink {
    public let config: CGEventCursorSinkConfiguration

    /// Current tracked cursor coordinate in screen space (top-left origin).
    public private(set) var currentPosition: CGPoint

    /// Cumulative count of move deltas received.
    public private(set) var moveCount: Int = 0

    /// Cumulative count of deltas suppressed due to delta.isLocked == true.
    public private(set) var lockedMoveCount: Int = 0

    /// Total distance traveled by the cursor in pixels.
    public private(set) var totalDistanceTraveled: Double = 0.0

    /// Total number of clicks dispatched.
    public private(set) var totalClicksCount: Int = 0

    /// Histogram of clicks categorized by source identifier (e.g. "roll_twist_cw", "hover_dwell").
    public private(set) var clickCountsBySource: [String: Int] = [:]

    /// History ring buffer of dispatched click events.
    public private(set) var recordedClicks: [ClickEvent] = []

    public init(config: CGEventCursorSinkConfiguration = CGEventCursorSinkConfiguration()) {
        self.config = config

        if let initPos = config.initialPosition {
            self.currentPosition = initPos
        } else if let sysPos = Self.querySystemCursorPosition() {
            self.currentPosition = sysPos
        } else {
            let bounds = config.customDisplayBounds ?? config.fallbackDisplayBounds
            self.currentPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    /// Returns the active bounding rectangle used for coordinate clamping.
    public func activeDisplayBounds() -> CGRect {
        if let custom = config.customDisplayBounds {
            return custom
        }
        let mainID = CGMainDisplayID()
        let bounds = CGDisplayBounds(mainID)
        if bounds.width <= 0 || bounds.height <= 0 || bounds.isNull || bounds.isInfinite {
            return config.fallbackDisplayBounds
        }
        return bounds
    }

    /// Clamps point coordinates within the given bounding rectangle.
    private func clamp(point: CGPoint, to bounds: CGRect) -> CGPoint {
        let minX = bounds.minX
        let maxX = max(minX, bounds.maxX - 0.001)
        let minY = bounds.minY
        let maxY = max(minY, bounds.maxY - 0.001)

        let clampedX = min(max(point.x, minX), maxX)
        let clampedY = min(max(point.y, minY), maxY)
        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Dispatches a relative cursor displacement delta.
    public func postMove(delta: CursorDelta) async {
        // Guard against non-finite values (NaN / Infinity)
        guard delta.dx.isFinite, delta.dy.isFinite else {
            return
        }

        // Gesture Lock Invariant: Strict 0.00 px cursor wander during axial roll twists
        if delta.isLocked {
            lockedMoveCount += 1
            return
        }

        let bounds = activeDisplayBounds()
        let candidate = CGPoint(
            x: currentPosition.x + delta.dx,
            y: currentPosition.y + delta.dy
        )
        let clamped = clamp(point: candidate, to: bounds)

        let stepDist = hypot(clamped.x - currentPosition.x, clamped.y - currentPosition.y)
        currentPosition = clamped
        moveCount += 1
        totalDistanceTraveled += stepDist

        // 1. Hardware Cursor Warping (moves physical pointer even when Accessibility TCC is pending)
        if config.isWarpCursorEnabled {
            CGWarpMouseCursorPosition(clamped)
        }

        // 2. Quartz Event Posting (notifies WindowServer and applications)
        if config.isEventPostingEnabled {
            if let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: clamped,
                mouseButton: .left
            ) {
                event.post(tap: config.tapLocation)
            }
        }
    }

    /// Dispatches a discrete mouse button click (left or right).
    public func postClick(type: ClickType) async {
        let now = ProcessInfo.processInfo.systemUptime
        let event = ClickEvent(type: type, timestamp: now, screenPosition: currentPosition)

        // Telemetry accounting
        totalClicksCount += 1
        clickCountsBySource[type.source, default: 0] += 1
        recordedClicks.append(event)
        if recordedClicks.count > config.maxClickHistory {
            recordedClicks.removeFirst()
        }

        // WindowServer event dispatch
        if config.isEventPostingEnabled {
            let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) = {
                if type.isLeftClick {
                    return (.leftMouseDown, .leftMouseUp, .left)
                } else {
                    return (.rightMouseDown, .rightMouseUp, .right)
                }
            }()

            // Down event
            if let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: downType,
                mouseCursorPosition: currentPosition,
                mouseButton: button
            ) {
                downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                downEvent.post(tap: config.tapLocation)
            }

            // Optional hold duration
            if config.clickHoldDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(config.clickHoldDuration * 1_000_000_000))
            }

            // Up event
            if let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: currentPosition,
                mouseButton: button
            ) {
                upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                upEvent.post(tap: config.tapLocation)
            }
        }
    }

    /// Resets internal telemetry, tracking counters, and cursor position.
    public func reset(to position: CGPoint? = nil) {
        if let pos = position {
            currentPosition = pos
        } else if let initPos = config.initialPosition {
            currentPosition = initPos
        } else {
            let bounds = activeDisplayBounds()
            currentPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        moveCount = 0
        lockedMoveCount = 0
        totalDistanceTraveled = 0.0
        totalClicksCount = 0
        clickCountsBySource.removeAll()
        recordedClicks.removeAll()
    }

    // MARK: - Static System Diagnostics

    /// Queries whether the current process is trusted for macOS Accessibility (TCC).
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Displays the system prompt requesting Accessibility permissions for the process.
    public static func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Queries whether an active macOS WindowServer console session is available.
    public static func isWindowServerAvailable() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool {
            return onConsole
        }
        if let onConsoleInt = session["kCGSSessionOnConsoleKey"] as? Int {
            return onConsoleInt == 1
        }
        return false
    }

    /// Queries the current physical cursor location from CoreGraphics.
    public static func querySystemCursorPosition() -> CGPoint? {
        if let event = CGEvent(source: nil) {
            return event.location
        }
        return nil
    }
}
