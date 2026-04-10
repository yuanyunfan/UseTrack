// UseTrack — macOS Activity Tracker
// UseTrackMenuBar: Menu Bar App 入口
//
// 使用 AppKit + NSPopover 实现 Menu Bar 状态栏应用。
// 不使用 @main 属性，因为这是 top-level code 入口。

import AppKit
import SwiftUI

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var statusViewModel = StatusViewModel()
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: "UseTrack")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover with SwiftUI view
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusView(viewModel: statusViewModel))

        // Update status every 30 seconds
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.statusViewModel.refresh()
        }

        // Initial update
        statusViewModel.refresh()
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}

// MARK: - Main Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
