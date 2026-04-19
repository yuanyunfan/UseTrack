// UseTrack — macOS Activity Tracker
// AFKWatcher: 检测用户是否空闲（Away From Keyboard）
//
// 职责:
// - 使用 CGEventSource.secondsSinceLastEventType 检测空闲时间（无需权限）
// - 超过阈值时记录 idle_start 事件，回推实际空闲开始时间
// - 用户回来时记录 idle_end 事件，包含空闲总时长

import Foundation
import CoreGraphics

/// Monitors user idle state by checking time since last input event.
/// Records idle_start and idle_end events to track away-from-keyboard periods.
class AFKWatcher {
    private let dbManager: DatabaseManager
    private var timer: Timer?
    private var isIdle: Bool = false
    private var idleStartTime: Date?
    private let idleThreshold: TimeInterval  // seconds before considered idle
    private let pollInterval: TimeInterval

    /// 回调：通知 TrackingEngine 空闲状态变化
    var onIdleStateChanged: ((Bool) -> Void)?

    /// Initialize AFK watcher.
    /// - Parameters:
    ///   - dbManager: Database manager for writing events
    ///   - idleThreshold: Seconds of inactivity before marking as idle (default: 300 = 5 min)
    ///   - pollInterval: How often to check idle state (default: 30 seconds)
    init(dbManager: DatabaseManager, idleThreshold: TimeInterval = 300, pollInterval: TimeInterval = 30) {
        self.dbManager = dbManager
        self.idleThreshold = idleThreshold
        self.pollInterval = pollInterval
    }

    func start() {
        // Guard against double-start: invalidate any existing timer first
        stop()

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkIdleState()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force-end an active idle session, writing idle_end to DB and resetting internal state.
    /// Called by TrackingEngine when resuming from .asleep/.locked to .active,
    /// to ensure no stale idle session is left unclosed (see Issue #101).
    func forceEndIdle() {
        guard isIdle else { return }
        let now = Date()
        let idleDuration = idleStartTime.map { now.timeIntervalSince($0) } ?? 0

        isIdle = false

        let event = ActivityEvent(
            id: nil,
            timestamp: now,
            activity: "idle_end",
            appName: nil,
            windowTitle: nil,
            durationSeconds: idleDuration,
            meta: ["idle_duration_s": String(Int(idleDuration)), "source": "force_end"],
            category: nil
        )

        do {
            let _ = try dbManager.insertActivity(event)
            print("[AFKWatcher] Force-ended idle session (was idle for \(Int(idleDuration))s)")
        } catch {
            print("[AFKWatcher] Error recording forced idle_end: \(error)")
        }

        idleStartTime = nil
    }

    private func checkIdleState() {
        let idleSeconds = getIdleTime()

        if idleSeconds >= idleThreshold && !isIdle {
            // User just became idle
            isIdle = true
            idleStartTime = Date().addingTimeInterval(-idleSeconds)  // Approximate when they actually went idle

            let event = ActivityEvent(
                id: nil,
                timestamp: idleStartTime!,
                activity: "idle_start",
                appName: nil,
                windowTitle: nil,
                durationSeconds: nil,
                meta: ["idle_threshold": String(Int(idleThreshold))],
                category: nil
            )

            do {
                let _ = try dbManager.insertActivity(event)
                print("[AFKWatcher] User is now idle (inactive for \(Int(idleSeconds))s)")
                onIdleStateChanged?(true)
            } catch {
                print("[AFKWatcher] Error recording idle_start: \(error)")
            }

        } else if idleSeconds < idleThreshold && isIdle {
            // User just came back
            let now = Date()
            let idleDuration = idleStartTime.map { now.timeIntervalSince($0) } ?? idleSeconds

            isIdle = false

            let event = ActivityEvent(
                id: nil,
                timestamp: now,
                activity: "idle_end",
                appName: nil,
                windowTitle: nil,
                durationSeconds: idleDuration,
                meta: ["idle_duration_s": String(Int(idleDuration))],
                category: nil
            )

            do {
                let _ = try dbManager.insertActivity(event)
                print("[AFKWatcher] User is back (was idle for \(Int(idleDuration))s)")
                onIdleStateChanged?(false)
            } catch {
                print("[AFKWatcher] Error recording idle_end: \(error)")
            }

            idleStartTime = nil
        }
    }

    /// Get seconds since last user input event (mouse move, key press, scroll, etc.)
    /// Uses CGEventSource which does NOT require any special permissions.
    private func getIdleTime() -> TimeInterval {
        // CGEventSourceSecondsSinceLastEventType returns the time in seconds
        // .combinedSessionState includes both local and remote (VNC) events
        let mouseMoved = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouseDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        let scrollWheel = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel)

        // Return the minimum (most recent activity)
        return min(mouseMoved, keyDown, mouseDown, scrollWheel)
    }
}
