// UseTrack — macOS Activity Tracker
// DashboardWindow: Dashboard 窗口管理

import AppKit
import SwiftUI

// MARK: - Notification Name

extension Notification.Name {
    static let openDashboard = Notification.Name("com.usetrack.openDashboard")
}

// MARK: - Dashboard Window Controller

class DashboardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = DashboardViewModel()

    private let windowWidth: CGFloat = 1400
    private let windowHeight: CGFloat = 900

    func showWindow(_ sender: Any?) {
        // If window already exists and visible, bring to front
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Close old window if it exists but is hidden.
        // 先置 nil 解除 delegate，再 close，避免触发 windowWillClose 的延迟回调干扰新窗口。
        let oldWindow = window
        window = nil
        oldWindow?.delegate = nil
        oldWindow?.close()

        // Create SwiftUI hosting controller
        let dashboardView = DashboardView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: dashboardView)

        // Create window with explicit size
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "UseTrack Dashboard"
        w.contentViewController = hostingController
        w.minSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false  // 防止关闭窗口时 window 被自动释放导致 app 退出
        w.delegate = self

        // Force the content size (overrides any cached frame)
        w.setContentSize(NSSize(width: windowWidth, height: windowHeight))
        w.center()

        // Follow system appearance
        w.appearance = nil

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Load data
        viewModel.refresh()
    }

    // When user closes the window, release it so next open creates fresh.
    // 延迟释放：windowWillClose 在关闭动画开始时调用，此时 _NSWindowTransformAnimation
    // 仍在进行中。立即置 nil 会导致动画对象 use-after-free (EXC_BAD_ACCESS)。
    // 等到下一个 RunLoop 周期，确保所有 CA transaction 和动画都已 flush 完成。
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.window = nil
        }
    }

    /// 关闭 Dashboard 窗口（由 Cmd+Q 替代动作调用）
    func closeWindow() {
        window?.close()
    }
}
