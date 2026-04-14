// UseTrack — macOS Activity Tracker
// BrowserURLWatcher: 使用 AppleScript 从浏览器获取当前 Tab 的 URL
//
// 支持的浏览器:
// - Google Chrome, Microsoft Edge, Brave Browser, Vivaldi, Arc (Chromium 系)
// - Safari (WebKit 系)
//
// 设计:
// - 被 WindowWatcher 在检测到浏览器前台时调用
// - 获取 URL 后写入 activity_stream (activity = "url_visit")
// - AppleScript 执行需要 Automation 权限（首次会弹授权对话框）
// - 使用 NSAppleScript 同步执行，超时由 macOS 系统控制

import Foundation

/// Extracts the current tab URL from supported browsers via AppleScript.
/// Called by WindowWatcher when a browser is detected in the foreground.
class BrowserURLWatcher {
    private let dbManager: DatabaseManager

    /// 浏览器 App 名称 → bundle ID 映射
    /// 用于判断前台 App 是否为已知浏览器
    static let supportedBrowsers: [String: String] = [
        "Google Chrome":    "com.google.Chrome",
        "Microsoft Edge":   "com.microsoft.edgemac",
        "Brave Browser":    "com.brave.Browser",
        "Vivaldi":          "com.vivaldi.Vivaldi",
        "Arc":              "company.thebrowser.Browser",
        "Safari":           "com.apple.Safari",
    ]

    /// Chromium 系浏览器（共享相同的 AppleScript 接口）
    private static let chromiumBrowsers: Set<String> = [
        "Google Chrome", "Microsoft Edge", "Brave Browser", "Vivaldi", "Arc",
    ]

    /// Serial queue to protect lastURL / lastAppName from concurrent access
    private let stateQueue = DispatchQueue(label: "com.usetrack.BrowserURLWatcher.state")

    /// 上次记录的 URL（防止同一 URL 重复写入）
    /// Access must be synchronized via `stateQueue`.
    private var lastURL: String?
    private var lastAppName: String?

    init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    /// 判断指定 App 是否为支持的浏览器
    static func isSupportedBrowser(_ appName: String) -> Bool {
        return supportedBrowsers[appName] != nil
    }

    /// 尝试获取浏览器当前 Tab 的 URL 和标题，并写入数据库。
    /// 由 WindowWatcher 在检测到浏览器标题变化时调用。
    ///
    /// - Parameters:
    ///   - appName: 浏览器应用名称（如 "Google Chrome"）
    ///   - windowTitle: 当前窗口标题（从 CGWindowList 获取）
    func captureURL(appName: String, windowTitle: String?) {
        guard Self.isSupportedBrowser(appName) else { return }

        // 在后台线程执行 AppleScript（避免阻塞 WindowWatcher 的 Timer）
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            guard let urlInfo = self.getActiveTabInfo(appName: appName) else {
                return
            }

            let url = urlInfo.url
            let tabTitle = urlInfo.title

            // 去重：同一浏览器 + 同一 URL 不重复记录（thread-safe）
            let isDuplicate: Bool = self.stateQueue.sync {
                if url == self.lastURL && appName == self.lastAppName {
                    return true
                }
                self.lastURL = url
                self.lastAppName = appName
                return false
            }
            guard !isDuplicate else { return }

            // 跳过空 URL 和内部页面
            guard !url.isEmpty,
                  !url.hasPrefix("chrome://"),
                  !url.hasPrefix("edge://"),
                  !url.hasPrefix("brave://"),
                  !url.hasPrefix("vivaldi://"),
                  !url.hasPrefix("about:") else { return }

            // 构建 meta 数据
            var meta: [String: String] = ["url": url]
            if let tabTitle = tabTitle, !tabTitle.isEmpty {
                meta["tab_title"] = tabTitle
            }

            let category = self.dbManager.getCategoryForApp(appName: appName)
            let event = ActivityEvent(
                id: nil,
                timestamp: Date(),
                activity: "url_visit",
                appName: appName,
                windowTitle: windowTitle,
                durationSeconds: nil,
                meta: meta,
                category: category
            )

            do {
                let _ = try self.dbManager.insertActivity(event)
            } catch {
                print("[BrowserURLWatcher] Error inserting url_visit: \(error)")
            }
        }
    }

    /// 当 App 切走或窗口标题变化为非浏览器时，重置去重状态
    func resetIfNeeded(appName: String) {
        if !Self.isSupportedBrowser(appName) {
            stateQueue.sync {
                lastURL = nil
                lastAppName = nil
            }
        }
    }

    // MARK: - AppleScript 执行

    private struct TabInfo {
        let url: String
        let title: String?
    }

    /// 通过 AppleScript 获取浏览器当前 Tab 的 URL 和标题
    private func getActiveTabInfo(appName: String) -> TabInfo? {
        let script: String

        if Self.chromiumBrowsers.contains(appName) {
            // Chromium 系浏览器共享 JavaScript 接口
            script = """
            tell application "\(appName)"
                if (count of windows) > 0 then
                    set tabURL to URL of active tab of front window
                    set tabTitle to title of active tab of front window
                    return tabURL & "|||" & tabTitle
                end if
            end tell
            """
        } else if appName == "Safari" {
            script = """
            tell application "Safari"
                if (count of windows) > 0 then
                    set tabURL to URL of current tab of front window
                    set tabTitle to name of current tab of front window
                    return tabURL & "|||" & tabTitle
                end if
            end tell
            """
        } else {
            return nil
        }

        guard let result = executeAppleScript(script) else { return nil }

        // 解析 "url|||title" 格式
        let parts = result.components(separatedBy: "|||")
        let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard !url.isEmpty else { return nil }
        return TabInfo(url: url, title: title)
    }

    /// 执行 AppleScript 并返回结果字符串
    private func executeAppleScript(_ source: String) -> String? {
        let appleScript = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)

        if let error = error {
            // -600: App not running, -1728: App not scriptable — 都是正常情况
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
            if errorNum != -600 && errorNum != -1728 {
                print("[BrowserURLWatcher] AppleScript error for: \(error)")
            }
            return nil
        }

        return result?.stringValue
    }
}
