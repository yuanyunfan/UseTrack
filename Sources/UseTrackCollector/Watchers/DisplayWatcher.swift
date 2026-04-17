// UseTrack — macOS Activity Tracker
// DisplayWatcher: 监听屏幕亮灭状态
//
// 职责:
// - 监听 NSWorkspace.screensDidSleepNotification / screensDidWakeNotification
// - 记录 display_sleep / display_wake 事件到 activity_stream
// - 暴露 isDisplayAsleep 状态供 AttentionScorer 使用
//
// 注意: 屏幕亮灭 ≠ 系统睡眠。屏幕可以因节能设置自动关闭，
// 而系统仍在运行（下载、编译等任务继续执行）。
// 这是比 AFKWatcher 更底层的"人不在"信号：屏幕灭 = 人一定不在看。

import Foundation
import AppKit

/// Monitors display (screen) sleep/wake state.
/// Display sleep is a stronger "away" signal than AFK — if the screen is off,
/// the user is definitely not looking at it.
class DisplayWatcher {
    private let dbManager: DatabaseManager
    private var observers: [NSObjectProtocol] = []
    private let lock = DispatchQueue(label: "com.usetrack.displaywatcher")

    /// Thread-safe display state
    private var _isDisplayAsleep: Bool = false
    var isDisplayAsleep: Bool {
        lock.sync { _isDisplayAsleep }
    }

    /// Display sleep start time (for calculating duration on wake)
    private var sleepStartTime: Date?

    /// Callback: notify when display state changes
    var onDisplayStateChanged: ((Bool) -> Void)?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        // Screen turned off (display sleep)
        let sleepObs = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDisplaySleep()
        }
        observers.append(sleepObs)

        // Screen turned on (display wake)
        let wakeObs = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDisplayWake()
        }
        observers.append(wakeObs)

        print("[DisplayWatcher] Started — monitoring screen sleep/wake")
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in observers {
            nc.removeObserver(obs)
        }
        observers.removeAll()
    }

    // MARK: - Event Handlers

    private func handleDisplaySleep() {
        let now = Date()
        lock.sync { _isDisplayAsleep = true }
        sleepStartTime = now

        let event = ActivityEvent(
            id: nil,
            timestamp: now,
            activity: "display_sleep",
            appName: nil,
            windowTitle: nil,
            durationSeconds: nil,
            meta: nil,
            category: nil
        )

        do {
            let _ = try dbManager.insertActivity(event)
            print("[DisplayWatcher] Display went to sleep")
            onDisplayStateChanged?(true)
        } catch {
            print("[DisplayWatcher] Error recording display_sleep: \(error)")
        }
    }

    private func handleDisplayWake() {
        let now = Date()
        let sleepDuration = sleepStartTime.map { now.timeIntervalSince($0) }

        lock.sync { _isDisplayAsleep = false }

        let event = ActivityEvent(
            id: nil,
            timestamp: now,
            activity: "display_wake",
            appName: nil,
            windowTitle: nil,
            durationSeconds: sleepDuration,
            meta: sleepDuration.map { ["sleep_duration_s": String(Int($0))] },
            category: nil
        )

        do {
            let _ = try dbManager.insertActivity(event)
            let durationStr = sleepDuration.map { " (display was off for \(Int($0))s)" } ?? ""
            print("[DisplayWatcher] Display woke up\(durationStr)")
            onDisplayStateChanged?(false)
        } catch {
            print("[DisplayWatcher] Error recording display_wake: \(error)")
        }

        sleepStartTime = nil
    }
}
