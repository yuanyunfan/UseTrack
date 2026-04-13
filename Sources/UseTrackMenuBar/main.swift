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
    let dashboardWindowController = DashboardWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start Collector subprocess (if not already running)
        startCollectorIfNeeded()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "UseTrack")
            button.image?.isTemplate = true
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

        // Listen for dashboard open notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openDashboard),
            name: .openDashboard,
            object: nil
        )

        // Initial update
        statusViewModel.refresh()
    }

    @objc func openDashboard() {
        popover.performClose(nil)
        dashboardWindowController.showWindow(nil)
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

    // MARK: - Collector Subprocess

    private var collectorProcess: Process?

    /// Launch UseTrackCollector as a subprocess, located next to this binary in the App bundle.
    private func startCollectorIfNeeded() {
        // Check if Collector is already running (e.g. from a previous launch)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", "UseTrackCollector"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        if check.terminationStatus == 0 {
            print("[UseTrack] Collector already running, skipping launch")
            return
        }

        // Find Collector binary next to this executable (same directory)
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let macOSDir = executableURL.deletingLastPathComponent()
        let collectorURL = macOSDir.appendingPathComponent("UseTrackCollector")
        let dbPath = NSHomeDirectory() + "/.usetrack/usetrack.db"

        print("[UseTrack] Looking for Collector at: \(collectorURL.path)")

        // Ensure data directory exists
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.usetrack",
            withIntermediateDirectories: true
        )

        guard FileManager.default.fileExists(atPath: collectorURL.path) else {
            print("[UseTrack] Collector not found at: \(collectorURL.path)")
            return
        }

        let process = Process()
        process.executableURL = collectorURL
        process.arguments = ["--db-path", dbPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            collectorProcess = process
            print("[UseTrack] Collector started (PID: \(process.processIdentifier))")
        } catch {
            print("[UseTrack] Failed to start Collector: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        collectorProcess?.terminate()
    }
}

// MARK: - Main Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
