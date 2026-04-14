// UseTrack — macOS Activity Tracker
// MouseTracker: 鼠标位置追踪 + hitTest
//
// 追踪全局鼠标位置、点击、滚动事件，为注意力评分提供交互信号。
// 使用 NSEvent.addGlobalMonitorForEvents 监听（需 Input Monitoring 权限）。
// 坐标系统一转换为 CG 坐标系（左上角原点），与 CGWindowList 保持一致。
// 所有共享状态通过 serialQueue 保护，确保线程安全。

import Foundation
import AppKit
import CoreGraphics

/// Tracks mouse position and interaction events for attention inference.
/// Records which window the mouse is hovering over, clicks, and scrolls.
/// Thread-safe: all mutable state is protected by a serial DispatchQueue.
class MouseTracker {
    // All mutable state protected by serialQueue
    private let serialQueue = DispatchQueue(label: "com.usetrack.mousetracker")

    /// Current global mouse position (Core Graphics coordinate system)
    private var _currentPosition: CGPoint = .zero

    /// Recent click events (timestamp + position), kept for the last 60 seconds
    private var _recentClicks: [(timestamp: Date, position: CGPoint)] = []

    /// Recent scroll events (timestamp + position), kept for the last 60 seconds
    private var _recentScrolls: [(timestamp: Date, position: CGPoint)] = []

    /// Last time mouse was moved
    private var _lastMoveTime: Date = Date()

    private var eventMonitors: [Any] = []
    private let retentionInterval: TimeInterval = 60  // Keep events for 60 seconds

    func start() {
        // Guard against double-start: remove any existing monitors first
        stop()

        // Monitor mouse movement (global, across all apps)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.handleMouseMove(event)
        }) {
            eventMonitors.append(monitor)
        }

        // Monitor mouse clicks
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            self?.handleMouseClick(event)
        }) {
            eventMonitors.append(monitor)
        }

        // Monitor scroll events
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            self?.handleScroll(event)
        }) {
            eventMonitors.append(monitor)
        }
    }

    func stop() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    // MARK: - Event Handlers (called on event monitor thread)

    private func handleMouseMove(_ event: NSEvent) {
        let cocoaPos = NSEvent.mouseLocation
        let cgPos = convertToCGCoordinates(cocoaPos)
        serialQueue.async {
            self._currentPosition = cgPos
            self._lastMoveTime = Date()
        }
    }

    private func handleMouseClick(_ event: NSEvent) {
        let cocoaPos = NSEvent.mouseLocation
        let cgPos = convertToCGCoordinates(cocoaPos)
        let now = Date()
        serialQueue.async {
            self._recentClicks.append((timestamp: now, position: cgPos))
            self.cleanupOldEvents()
        }
    }

    private func handleScroll(_ event: NSEvent) {
        let cocoaPos = NSEvent.mouseLocation
        let cgPos = convertToCGCoordinates(cocoaPos)
        let now = Date()
        serialQueue.async {
            self._recentScrolls.append((timestamp: now, position: cgPos))
            self.cleanupOldEvents()
        }
    }

    // MARK: - Query Methods (thread-safe, called from AttentionScorer timer)

    /// Check if the mouse is currently within a window's bounds
    func isMouseInBounds(_ bounds: CGRect) -> Bool {
        return serialQueue.sync { bounds.contains(_currentPosition) }
    }

    /// Check if there was a click within a window in the last N seconds
    func hadClickInWindow(bounds: CGRect, withinSeconds: TimeInterval = 30) -> Bool {
        return serialQueue.sync {
            let cutoff = Date().addingTimeInterval(-withinSeconds)
            return _recentClicks.contains { $0.timestamp > cutoff && bounds.contains($0.position) }
        }
    }

    /// Check if there was a scroll within a window in the last N seconds
    func hadScrollInWindow(bounds: CGRect, withinSeconds: TimeInterval = 60) -> Bool {
        return serialQueue.sync {
            let cutoff = Date().addingTimeInterval(-withinSeconds)
            return _recentScrolls.contains { $0.timestamp > cutoff && bounds.contains($0.position) }
        }
    }

    /// Calculate the percentage of time the mouse was in a window's bounds
    func mouseInBoundsRatio(bounds: CGRect) -> Double {
        return serialQueue.sync {
            bounds.contains(_currentPosition) ? 1.0 : 0.0
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert Cocoa coordinates (bottom-left origin) to CG coordinates (top-left origin)
    private func convertToCGCoordinates(_ cocoaPoint: CGPoint) -> CGPoint {
        guard let mainScreen = NSScreen.screens.first else { return cocoaPoint }
        let screenHeight = mainScreen.frame.height
        return CGPoint(x: cocoaPoint.x, y: screenHeight - cocoaPoint.y)
    }

    // MARK: - Cleanup (must be called within serialQueue)

    private func cleanupOldEvents() {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        _recentClicks.removeAll { $0.timestamp < cutoff }
        _recentScrolls.removeAll { $0.timestamp < cutoff }
    }
}
