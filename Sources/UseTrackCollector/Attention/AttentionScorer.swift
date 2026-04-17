// UseTrack — macOS Activity Tracker
// AttentionScorer: 多屏注意力评分引擎
//
// 多信号融合评分模型:
//   score = 10.0 × is_keyboard_focused
//         +  8.0 × had_click_in_window(30s)
//         +  5.0 × mouse_in_bounds
//         +  3.0 × had_scroll_in_window(60s)
//         +  1.0 × is_visible_on_screen
//         -  decay × seconds_since_last_interaction
//
// 判定规则:
//   score >= 10  → activeFocus
//   score ∈ [3, 10) → activeReference
//   score ∈ [1, 3)  → passiveVisible
//   score < 1       → stale

import Foundation
import AppKit

/// Scored window: a visible window with its computed attention score and state.
struct ScoredWindow {
    let window: VisibleWindow
    let score: Double
    let attention: AttentionState
}

/// Multi-signal attention scoring engine.
/// Combines keyboard focus, mouse position, click/scroll history, and time decay
/// to classify each visible window's attention state.
class AttentionScorer {
    private let screenDetector: ScreenDetector
    private let mouseTracker: MouseTracker
    private let dbManager: DatabaseManager
    private weak var displayWatcher: DisplayWatcher?

    /// Per-window last interaction timestamps (app name -> last interaction date)
    private var lastInteraction: [String: Date] = [:]

    /// Scoring weights (configurable)
    struct Weights {
        var keyboardFocus: Double = 10.0
        var recentClick: Double = 8.0
        var mouseInBounds: Double = 5.0
        var recentScroll: Double = 3.0
        var visibleOnScreen: Double = 1.0
        var decayPerSecond: Double = 0.01  // Score decay per second since last interaction
    }

    /// Score thresholds for attention state classification
    struct Thresholds {
        var activeFocus: Double = 10.0     // >= 10 → activeFocus
        var activeReference: Double = 3.0   // >= 3  → activeReference
        var passiveVisible: Double = 1.0    // >= 1  → passiveVisible
        // < 1 → stale
    }

    var weights = Weights()
    var thresholds = Thresholds()

    init(screenDetector: ScreenDetector, mouseTracker: MouseTracker, dbManager: DatabaseManager) {
        self.screenDetector = screenDetector
        self.mouseTracker = mouseTracker
        self.dbManager = dbManager
    }

    /// Set display watcher reference for display-state-aware scoring.
    /// Called after DisplayWatcher is created to avoid circular init dependency.
    func setDisplayWatcher(_ watcher: DisplayWatcher) {
        self.displayWatcher = watcher
    }

    // MARK: - Core Scoring

    /// Score all visible windows and return their attention states.
    func scoreAllWindows() -> [ScoredWindow] {
        // If display is asleep, all windows are stale — no one is looking
        if displayWatcher?.isDisplayAsleep == true {
            let visibleWindows = screenDetector.getVisibleWindows()
            return visibleWindows.compactMap { window -> ScoredWindow? in
                if dbManager.isSensitiveApp(appName: window.appName) { return nil }
                return ScoredWindow(window: window, score: 0, attention: .stale)
            }
        }

        let visibleWindows = screenDetector.getVisibleWindows()
        let focusedWindow = screenDetector.getFocusedWindow()
        let now = Date()

        let results = visibleWindows.compactMap { window -> ScoredWindow? in
            // Skip sensitive apps
            if dbManager.isSensitiveApp(appName: window.appName) { return nil }

            let score = computeScore(
                window: window,
                isFocused: focusedWindow.map { $0.ownerPID == window.ownerPID && $0.bounds == window.bounds } ?? false,
                now: now
            )

            let attention = classifyAttention(score: score)

            // Update last interaction time if there's active engagement
            if score >= thresholds.activeReference {
                lastInteraction[window.appName] = now
            }

            return ScoredWindow(window: window, score: score, attention: attention)
        }

        // Cleanup stale entries: keep only apps currently visible or interacted within 10 minutes
        let visibleAppNames = Set(visibleWindows.map { $0.appName })
        let cutoff = now.addingTimeInterval(-600) // 10 minutes
        lastInteraction = lastInteraction.filter { key, date in
            visibleAppNames.contains(key) || date > cutoff
        }

        return results
    }

    /// Compute attention score for a single window.
    private func computeScore(window: VisibleWindow, isFocused: Bool, now: Date) -> Double {
        var score: Double = 0

        // Signal 1: Keyboard focus (strongest signal)
        if isFocused {
            score += weights.keyboardFocus
        }

        // Signal 2: Recent click in window bounds (strong signal)
        if mouseTracker.hadClickInWindow(bounds: window.bounds, withinSeconds: 30) {
            score += weights.recentClick
        }

        // Signal 3: Mouse currently in window bounds (medium signal)
        if mouseTracker.isMouseInBounds(window.bounds) {
            score += weights.mouseInBounds
        }

        // Signal 4: Recent scroll in window bounds (medium signal)
        if mouseTracker.hadScrollInWindow(bounds: window.bounds, withinSeconds: 60) {
            score += weights.recentScroll
        }

        // Signal 5: Visible on screen (weak signal)
        if window.isOnScreen {
            score += weights.visibleOnScreen
        }

        // Decay: reduce score based on time since last interaction
        if let lastTime = lastInteraction[window.appName] {
            let elapsed = now.timeIntervalSince(lastTime)
            score -= weights.decayPerSecond * elapsed
        }

        return max(score, 0)
    }

    /// Classify attention state based on score.
    private func classifyAttention(score: Double) -> AttentionState {
        if score >= thresholds.activeFocus {
            return .activeFocus
        } else if score >= thresholds.activeReference {
            return .activeReference
        } else if score >= thresholds.passiveVisible {
            return .passiveVisible
        } else {
            return .stale
        }
    }

    // MARK: - Snapshot Generation

    /// Generate window snapshots for all visible windows.
    /// Call this periodically (e.g., every 60 seconds) and write to database.
    func generateSnapshots() -> [WindowSnapshot] {
        let scored = scoreAllWindows()
        let now = Date()

        return scored.map { sw in
            WindowSnapshot(
                timestamp: now,
                screenIndex: sw.window.screenIndex,
                appName: sw.window.appName,
                windowTitle: sw.window.windowTitle,
                attention: sw.attention,
                score: sw.score,
                bounds: sw.window.bounds
            )
        }
    }

    /// Generate snapshots and write them to the database.
    func captureAndStore() {
        let snapshots = generateSnapshots()
        guard !snapshots.isEmpty else { return }

        do {
            try dbManager.insertWindowSnapshots(snapshots)
        } catch {
            print("[AttentionScorer] Error storing snapshots: \(error)")
        }
    }
}
