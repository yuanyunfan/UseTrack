// UseTrack — macOS Activity Tracker
// AppearanceManager: 管理应用外观主题（浅色/深色/跟随系统）

import AppKit
import SwiftUI
import Combine

/// 外观模式选项
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case dark = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 返回对应的 NSAppearance，auto 返回 nil（跟随系统）
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 管理全局外观设置，持久化到 UserDefaults
class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()

    private let defaultsKey = "com.usetrack.appearanceMode"

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
            applyAppearance()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: defaultsKey) ?? "auto"
        self.mode = AppearanceMode(rawValue: saved) ?? .auto
    }

    /// 将外观应用到所有窗口
    func applyAppearance() {
        let appearance = mode.nsAppearance
        // Apply to app-level (affects all new windows)
        NSApp.appearance = appearance
        // Apply to all existing windows
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
