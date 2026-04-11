// UseTrack — macOS Activity Tracker
// DashboardWindow: Dashboard 窗口管理
//
// 管理 NSWindow 的创建和生命周期，托管 SwiftUI DashboardView。

import AppKit
import SwiftUI

// MARK: - Notification Name

extension Notification.Name {
    static let openDashboard = Notification.Name("com.usetrack.openDashboard")
}

// MARK: - Dashboard Window Controller

class DashboardWindowController {
    private var window: NSWindow?
    private let viewModel = DashboardViewModel()

    func showWindow(_ sender: Any?) {
        // If window already exists, bring to front
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create SwiftUI hosting controller
        let dashboardView = DashboardView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: dashboardView)

        // Create window
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "UseTrack Dashboard"
        w.contentViewController = hostingController
        w.minSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false
        w.center()

        // Set window appearance to follow system
        w.appearance = nil

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Load initial data
        viewModel.refresh()
    }
}
