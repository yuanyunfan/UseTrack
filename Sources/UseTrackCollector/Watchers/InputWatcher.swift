// UseTrack — macOS Activity Tracker
// InputWatcher: 输入活跃度统计（击键/点击/滚动计数，不记录按键内容）

import Foundation
import AppKit
import CoreGraphics

/// Monitors keyboard and mouse activity frequency.
/// Records keystrokes-per-minute and clicks-per-minute as aggregated metrics.
/// DOES NOT record actual key content — only counts.
class InputWatcher {
    private let dbManager: DatabaseManager
    private var timer: Timer?
    private var eventMonitors: [Any] = []

    // Per-minute counters — protected by serialQueue for thread safety
    private let serialQueue = DispatchQueue(label: "com.usetrack.inputwatcher")
    private var keystrokeCount: Int = 0
    private var mouseClickCount: Int = 0
    private var scrollCount: Int = 0
    private let aggregateInterval: TimeInterval = 60 // 1 minute

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    func start() {
        // Reset counters to avoid carrying over stale counts from a previous period
        serialQueue.sync {
            keystrokeCount = 0
            mouseClickCount = 0
            scrollCount = 0
        }

        // Monitor keystrokes (count only, not content)
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.serialQueue.async { self?.keystrokeCount += 1 }
        }) {
            eventMonitors.append(monitor)
        }

        // Monitor mouse clicks
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.serialQueue.async { self?.mouseClickCount += 1 }
        }) {
            eventMonitors.append(monitor)
        }

        // Monitor scroll
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] _ in
            self?.serialQueue.async { self?.scrollCount += 1 }
        }) {
            eventMonitors.append(monitor)
        }

        // Aggregate and record every minute
        timer = Timer.scheduledTimer(withTimeInterval: aggregateInterval, repeats: true) { [weak self] _ in
            self?.recordAndReset()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        // Flush any pending counts before removing monitors
        recordAndReset()

        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }

    private func recordAndReset() {
        // Atomically read and reset counters
        var ks = 0, mc = 0, sc = 0
        serialQueue.sync {
            ks = keystrokeCount
            mc = mouseClickCount
            sc = scrollCount
            keystrokeCount = 0
            mouseClickCount = 0
            scrollCount = 0
        }

        // Skip if no activity
        guard ks > 0 || mc > 0 || sc > 0 else { return }

        // Get current foreground app
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        let event = ActivityEvent(
            id: nil,
            timestamp: Date(),
            activity: "typing",
            appName: appName,
            windowTitle: nil,
            durationSeconds: aggregateInterval,
            meta: [
                "keystrokes_per_min": String(ks),
                "clicks_per_min": String(mc),
                "scrolls_per_min": String(sc)
            ],
            category: dbManager.getCategoryForApp(appName: appName)
        )

        do {
            let _ = try dbManager.insertActivity(event)
        } catch {
            print("[InputWatcher] Error: \(error)")
        }
    }
}
