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

        // Close old window if it exists but is hidden
        window?.close()
        window = nil

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

    // When user closes the window, release it so next open creates fresh
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
