// UseTrack — macOS Activity Tracker
// WindowWatcher: 定期轮询前台窗口标题，检测同 App 内的标题变化（如切换浏览器 Tab、编辑器文件）
//
// 实现方式:
// - 使用 CGWindowListCopyWindowInfo 获取窗口标题（需要 Screen Recording 权限）
// - 每 5 秒轮询一次（可配置）
// - 仅在标题实际变化时写入 activity_stream（activity = "focus"）
// - 跳过 sensitive_apps 黑名单中的 App

import Foundation
import AppKit
import CoreGraphics

/// Periodically polls the focused window title using CGWindowListCopyWindowInfo.
/// Detects title changes within the same app (e.g., switching browser tabs, editor files).
/// Requires Screen Recording permission for full window title access.
class WindowWatcher {
    private let dbManager: DatabaseManager
    private var timer: Timer?
    private var lastWindowTitle: String?
    private var lastAppName: String?
    private let pollInterval: TimeInterval

    init(dbManager: DatabaseManager, pollInterval: TimeInterval = 5.0) {
        self.dbManager = dbManager
        self.pollInterval = pollInterval
    }

    func start() {
        // Poll every N seconds for window title changes
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkWindowTitle()
        }
        // Fire immediately on start
        checkWindowTitle()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkWindowTitle() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"

        // Skip sensitive apps
        if dbManager.isSensitiveApp(appName: appName) { return }

        // Get focused window title via CGWindowList
        let title = getFocusedWindowTitle(pid: frontApp.processIdentifier)

        // Only record if title changed (within the same app, title change = tab/file switch)
        guard title != lastWindowTitle || appName != lastAppName else { return }

        // Don't record if title is nil or empty
        guard let title = title, !title.isEmpty else {
            lastWindowTitle = nil
            lastAppName = appName
            return
        }

        lastWindowTitle = title
        lastAppName = appName

        // Record as a focus event (within-app navigation)
        let category = dbManager.getCategoryForApp(appName: appName)
        let event = ActivityEvent(
            id: nil,
            timestamp: Date(),
            activity: "focus",
            appName: appName,
            windowTitle: title,
            durationSeconds: nil,
            meta: nil,
            category: category
        )

        do {
            let _ = try dbManager.insertActivity(event)
        } catch {
            print("[WindowWatcher] Error inserting focus event: \(error)")
        }
    }

    /// Get the title of the frontmost window for a given process.
    /// Uses CGWindowListCopyWindowInfo which requires Screen Recording permission.
    private func getFocusedWindowTitle(pid: pid_t) -> String? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Find windows belonging to the frontmost app, sorted by layer (lower = more visible)
        let appWindows = windowList.filter { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return ownerPID == pid
        }.sorted { a, b in
            let layerA = a[kCGWindowLayer as String] as? Int ?? 999
            let layerB = b[kCGWindowLayer as String] as? Int ?? 999
            return layerA < layerB
        }

        // Return the title of the topmost window
        for window in appWindows {
            if let name = window[kCGWindowName as String] as? String, !name.isEmpty {
                return name
            }
        }

        return nil
    }
}
