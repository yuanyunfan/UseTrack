// UseTrack — macOS Activity Tracker
// WindowWatcher: 定期轮询前台窗口标题，检测同 App 内的标题变化（如切换浏览器 Tab、编辑器文件）
//
// 实现方式:
// - 使用 CGWindowListCopyWindowInfo 获取窗口标题（需要 Screen Recording 权限）
// - 自适应轮询间隔: 活跃 3s → 稳定 6s → 深度专注 12s
// - 仅在标题实际变化时写入 activity_stream（activity = "focus"）
// - 标题变化 2s 防抖，避免页面加载时标题闪烁产生 micro-event
// - 浏览器前台时通过 AppleScript 获取 URL
// - 跳过 sensitive_apps 黑名单中的 App

import Foundation
import AppKit
import CoreGraphics

/// 自适应轮询级别
private enum PollLevel: CustomStringConvertible {
    case active     // 最近 30s 有标题变化，高频轮询
    case stable     // 30s-5min 无变化
    case deepFocus  // 5min+ 无变化

    var interval: TimeInterval {
        switch self {
        case .active:    return 3.0
        case .stable:    return 6.0
        case .deepFocus: return 12.0
        }
    }

    var description: String {
        switch self {
        case .active:    return "active(\(interval)s)"
        case .stable:    return "stable(\(interval)s)"
        case .deepFocus: return "deepFocus(\(interval)s)"
        }
    }
}

/// Periodically polls the focused window title using CGWindowListCopyWindowInfo.
/// Detects title changes within the same app (e.g., switching browser tabs, editor files).
/// Uses adaptive polling intervals and title debounce for energy efficiency.
/// Requires Screen Recording permission for full window title access.
class WindowWatcher {
    private let dbManager: DatabaseManager
    private let browserURLWatcher: BrowserURLWatcher
    private var timer: Timer?
    private var lastWindowTitle: String?
    private var lastAppName: String?

    // 自适应轮询状态
    private var currentPollLevel: PollLevel = .active
    private var lastChangeTime: Date = Date()

    // 标题防抖: 同一 App + 同一 URL 的标题变化有 2s 防抖
    private static let debounceInterval: TimeInterval = 2.0
    private var pendingTitle: String?
    private var pendingAppName: String?
    private var debounceTimer: Timer?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
        self.browserURLWatcher = BrowserURLWatcher(dbManager: dbManager)
    }

    func start() {
        scheduleTimer()
        // Fire immediately on start
        checkWindowTitle()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    // MARK: - Adaptive Polling

    /// 根据上下文变化频率调整轮询间隔
    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: currentPollLevel.interval,
            repeats: true
        ) { [weak self] _ in
            self?.checkWindowTitle()
        }
        // 设置 leeway 允许系统合并唤醒（省电）
        timer?.tolerance = currentPollLevel.interval * 0.2
    }

    /// 更新轮询级别（如果变化则重新调度 Timer）
    private func updatePollLevel() {
        let elapsed = Date().timeIntervalSince(lastChangeTime)
        let newLevel: PollLevel

        if elapsed < 30 {
            newLevel = .active
        } else if elapsed < 300 {
            newLevel = .stable
        } else {
            newLevel = .deepFocus
        }

        if newLevel != currentPollLevel {
            currentPollLevel = newLevel
            scheduleTimer()
        }
    }

    // MARK: - Window Title Check

    // 最后一次窗口信息（用于传递给记录函数）
    private var lastWindowInfo: WindowInfo?

    private func checkWindowTitle() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"

        // Skip sensitive apps
        if dbManager.isSensitiveApp(appName: appName) { return }

        // Get focused window info via AX API (fallback to CGWindowList)
        let windowInfo = getFocusedWindowInfo(pid: frontApp.processIdentifier)
        let title = windowInfo?.title

        // Only record if title changed (within the same app, title change = tab/file switch)
        guard title != lastWindowTitle || appName != lastAppName else {
            // 无变化，检查是否需要降低轮询频率
            updatePollLevel()
            return
        }

        // Don't record if title is nil or empty
        guard let title = title, !title.isEmpty else {
            lastWindowTitle = nil
            lastAppName = appName
            return
        }

        // App 切换立即触发（无需防抖）
        if appName != lastAppName {
            lastWindowTitle = title
            lastAppName = appName
            lastWindowInfo = windowInfo
            lastChangeTime = Date()
            currentPollLevel = .active
            scheduleTimer()

            recordTitleChange(appName: appName, title: title, windowInfo: windowInfo)
            return
        }

        // 同一 App 内标题变化：2s 防抖
        pendingTitle = title
        pendingAppName = appName
        lastWindowInfo = windowInfo
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval,
            repeats: false
        ) { [weak self] _ in
            self?.flushPendingTitle()
        }
    }

    /// 防抖结束后刷新标题
    private func flushPendingTitle() {
        guard let title = pendingTitle, let appName = pendingAppName else { return }

        // 再次检查去重（防抖期间可能又变回来了）
        guard title != lastWindowTitle || appName != lastAppName else { return }

        lastWindowTitle = title
        lastAppName = appName
        lastChangeTime = Date()
        currentPollLevel = .active
        scheduleTimer()

        recordTitleChange(appName: appName, title: title, windowInfo: lastWindowInfo)

        pendingTitle = nil
        pendingAppName = nil
    }

    /// 记录标题变化事件
    private func recordTitleChange(appName: String, title: String, windowInfo: WindowInfo?) {
        // 如果是浏览器，尝试通过 AppleScript 获取 URL
        if BrowserURLWatcher.isSupportedBrowser(appName) {
            browserURLWatcher.captureURL(appName: appName, windowTitle: title)
        } else {
            browserURLWatcher.resetIfNeeded(appName: appName)
        }

        // Record as a focus event (within-app navigation)
        var meta: [String: String]? = nil
        if let info = windowInfo {
            var m: [String: String] = [:]
            if let docPath = info.documentPath {
                m["document_path"] = docPath
            }
            if info.isFullScreen {
                m["is_full_screen"] = "true"
            }
            if !m.isEmpty { meta = m }
        }

        let category = dbManager.getCategoryForApp(appName: appName)
        let event = ActivityEvent(
            id: nil,
            timestamp: Date(),
            activity: "focus",
            appName: appName,
            windowTitle: title,
            durationSeconds: nil,
            meta: meta,
            category: category
        )

        do {
            let _ = try dbManager.insertActivity(event)
        } catch {
            print("[WindowWatcher] Error inserting focus event: \(error)")
        }
    }

    // MARK: - CGWindowList

    /// 窗口信息结构体（整合 CGWindowList + AX API 的结果）
    private struct WindowInfo {
        let title: String
        let documentPath: String?
        let isFullScreen: Bool
    }

    /// 获取前台窗口的完整信息，优先用 AX API，降级到 CGWindowList。
    /// AX API 能获取 documentPath 和 isFullScreen；CGWindowList 只能获取标题。
    private func getFocusedWindowInfo(pid: pid_t) -> WindowInfo? {
        // 尝试 AX API（需要 Accessibility 权限）
        if let axInfo = getWindowInfoViaAX(pid: pid) {
            return axInfo
        }
        // 降级到 CGWindowList
        if let title = getFocusedWindowTitle(pid: pid) {
            return WindowInfo(title: title, documentPath: nil, isFullScreen: false)
        }
        return nil
    }

    /// 通过 Accessibility API 获取窗口信息（一次查询获取所有属性）
    private func getWindowInfoViaAX(pid: pid_t) -> WindowInfo? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?

        // 获取 focused window
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return nil }

        let windowElement = window as! AXUIElement

        // 标题
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String, !title.isEmpty else { return nil }

        // 文档路径（编辑器、IDE 等会提供）
        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, kAXDocumentAttribute as CFString, &docRef)
        var documentPath: String? = nil
        if let docURL = docRef as? String {
            // AXDocument 返回 file:// URL，转为路径
            if let url = URL(string: docURL) {
                documentPath = url.path
            } else {
                documentPath = docURL
            }
        }

        // 全屏状态
        var fullScreenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(windowElement, "AXFullScreen" as CFString, &fullScreenRef)
        let isFullScreen = (fullScreenRef as? Bool) ?? false

        return WindowInfo(title: title, documentPath: documentPath, isFullScreen: isFullScreen)
    }

    /// Get the title of the frontmost window for a given process.
    /// Uses CGWindowListCopyWindowInfo which requires Screen Recording permission.
    /// Fallback when Accessibility API is unavailable.
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
