// UseTrack — macOS Activity Tracker
// AppWatcher: 监听前台应用切换事件
//
// 职责:
// - 使用 NSWorkspace.didActivateApplicationNotification 监听应用切换
// - 记录 app bundle ID、应用名称、切换时间
// - 计算每个应用的使用时长（切换时回填上条记录的 duration）
// - 敏感 App 脱敏处理（记为 "[Redacted]"）
// - 生成 ActivityEvent 并写入 DatabaseManager

import Foundation
import AppKit

/// Monitors foreground application changes via NSWorkspace notifications.
/// When the user switches to a different app, records an activity event
/// and backfills the duration of the previous event.
class AppWatcher {
    private let dbManager: DatabaseManager
    private var lastSwitchTime: Date?
    private var lastAppName: String?

    /// System processes that should never be recorded as user activity.
    /// These are macOS internal processes that become "frontmost" during
    /// lock screen, notifications, screenshots, etc.
    private static let ignoredApps: Set<String> = [
        "loginwindow",              // Lock screen / login
        "ScreenSaverEngine",        // Screen saver
        "UserNotificationCenter",   // Notification banners
        "SecurityAgent",            // Password prompts
        "ScreenCaptureUI",          // Screenshot UI (Cmd+Shift+4)
        "universalAccessAuthWarn",  // Accessibility prompts
        "CoreServicesUIAgent",      // System dialogs
        "AXVisualSupportAgent",     // Accessibility
        "OSDUIHelper",              // Volume/brightness overlay
    ]

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    /// Start monitoring app switches.
    /// Subscribes to NSWorkspace.didActivateApplicationNotification.
    func start() {
        // 1. Record current foreground app as initial state AND write to DB
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let appName = frontApp.localizedName ?? "Unknown"
            let bundleId = frontApp.bundleIdentifier ?? ""

            // Skip system processes
            guard !Self.ignoredApps.contains(appName) else {
                // Still set up the observer
                NSWorkspace.shared.notificationCenter.addObserver(
                    self,
                    selector: #selector(appDidActivate(_:)),
                    name: NSWorkspace.didActivateApplicationNotification,
                    object: nil
                )
                return
            }

            lastAppName = appName
            lastSwitchTime = Date()

            if !dbManager.isSensitiveApp(appName: appName) {
                let category = dbManager.getCategoryForApp(appName: appName)
                let event = ActivityEvent(
                    id: nil,
                    timestamp: Date(),
                    activity: "app_switch",
                    appName: appName,
                    windowTitle: nil,
                    durationSeconds: nil,
                    meta: ["bundle_id": bundleId],
                    category: category
                )
                try? dbManager.insertActivity(event)
            }
        }

        // 2. Subscribe to app activation notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// Stop monitoring and remove observer.
    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func appDidActivate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }

        let now = Date()
        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier ?? ""

        // Skip if same app (sometimes fires duplicate notifications)
        guard appName != lastAppName else { return }

        // Skip system processes that aren't real user activity
        if Self.ignoredApps.contains(appName) {
            // Don't update lastSwitchTime — the previous app is still "in use"
            // (e.g. lock screen shouldn't count as switching away from Cursor)
            return
        }

        // Check sensitive app blacklist
        if dbManager.isSensitiveApp(appName: appName) {
            recordSwitch(appName: "[Redacted]", bundleId: bundleId, windowTitle: nil, at: now)
        } else {
            recordSwitch(appName: appName, bundleId: bundleId, windowTitle: nil, at: now)
        }
    }

    private func recordSwitch(appName: String, bundleId: String, windowTitle: String?, at time: Date) {
        // 1. Backfill duration of previous event
        if let lastTime = lastSwitchTime {
            let duration = time.timeIntervalSince(lastTime)
            try? dbManager.updateLastActivityDuration(durationSeconds: duration)
        }

        // 2. Get category from app_rules
        let category = dbManager.getCategoryForApp(appName: appName)

        // 3. Create new activity event
        let event = ActivityEvent(
            id: nil,
            timestamp: time,
            activity: "app_switch",
            appName: appName,
            windowTitle: windowTitle,
            durationSeconds: nil,  // Will be backfilled on next switch
            meta: ["bundle_id": bundleId],
            category: category
        )

        // 4. Write to database
        do {
            let _ = try dbManager.insertActivity(event)
        } catch {
            print("[AppWatcher] Error inserting activity: \(error)")
        }

        // 5. Update state
        lastSwitchTime = time
        lastAppName = appName
    }
}
