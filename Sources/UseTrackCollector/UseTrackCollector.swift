// UseTrack — macOS Activity Tracker
// Entry point: 解析 CLI 参数并启动 RunLoop 保持进程常驻

import Foundation
import ArgumentParser
import CoreGraphics

// MARK: - Global references to keep Watchers alive during RunLoop
// ARC would release local variables; these statics ensure lifetime matches the process.
private var keepAlive: [AnyObject] = []
private var keepAliveTimers: [Timer] = []

@main
struct UseTrackCollector: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "UseTrack — macOS activity collector daemon"
    )

    @Option(name: .shortAndLong, help: "Path to SQLite database")
    var dbPath: String = "~/.usetrack/usetrack.db"

    @Option(name: .long, help: "Comma-separated Git repo base paths to scan")
    var gitPaths: String = "~/ProjectRepo"

    @Option(name: .long, help: "Obsidian vault path to monitor")
    var vaultPath: String = "~/Documents/NotionSync"

    @Flag(name: .shortAndLong, help: "Run in verbose mode")
    var verbose: Bool = false

    func run() throws {
        let expandedPath = NSString(string: dbPath).expandingTildeInPath
        let db = try DatabaseManager(dbPath: expandedPath)

        if verbose { print("Database initialized at: \(expandedPath)") }

        // --- Phase 1: Core Watchers ---

        let appWatcher = AppWatcher(dbManager: db)
        appWatcher.start()

        let windowWatcher = WindowWatcher(dbManager: db)
        windowWatcher.start()

        // Check Screen Recording permission
        if !Self.checkScreenRecordingPermission() {
            print("  ⚠️ Screen Recording permission not granted. Window titles will be empty.")
            print("     Grant in: System Settings → Privacy & Security → Screen Recording")
        }

        let afkWatcher = AFKWatcher(dbManager: db)
        afkWatcher.start()

        print("UseTrack Collector running.")
        print("  ✓ App Watcher — monitoring app switches")
        print("  ✓ Window Watcher — polling window titles (5s interval)")
        print("  ✓ AFK Watcher — idle detection (5min threshold)")

        // --- Phase 2: Attention Engine ---

        let screenDetector = ScreenDetector()
        let mouseTracker = MouseTracker()
        mouseTracker.start()

        let attentionScorer = AttentionScorer(
            screenDetector: screenDetector,
            mouseTracker: mouseTracker,
            dbManager: db
        )

        let snapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            attentionScorer.captureAndStore()
        }

        print("  ✓ Attention Scorer — multi-screen window snapshots (60s interval)")
        print("  ✓ Mouse Tracker — tracking position, clicks, scrolls")

        // --- Phase 3: Extended Watchers ---

        let inputWatcher = InputWatcher(dbManager: db)
        inputWatcher.start()

        let gitRepoPaths = gitPaths.split(separator: ",").map {
            NSString(string: String($0).trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        }
        let gitWatcher = GitWatcher(dbManager: db, repoPaths: gitRepoPaths)
        gitWatcher.start()

        let expandedVaultPath = NSString(string: vaultPath).expandingTildeInPath
        let obsidianWatcher = ObsidianWatcher(dbManager: db, vaultPath: expandedVaultPath)
        obsidianWatcher.start()

        print("  ✓ Input Watcher — keystroke/click counting (1min aggregation)")
        print("  ✓ Git Watcher — scanning repos for commits (5min interval)")
        print("  ✓ Obsidian Watcher — tracking note word counts (5min interval)")

        if verbose {
            print("  Database: \(expandedPath)")
        }

        // --- Keep all objects alive for the process lifetime ---
        keepAlive = [
            appWatcher, windowWatcher, afkWatcher,
            screenDetector, mouseTracker, attentionScorer,
            inputWatcher, gitWatcher, obsidianWatcher,
        ]
        keepAliveTimers = [snapshotTimer]

        // --- Graceful shutdown on SIGTERM/SIGINT ---
        signal(SIGTERM) { sig in
            print("\nUseTrack Collector shutting down (signal \(sig))...")
            for obj in keepAlive {
                if let w = obj as? AppWatcher { w.stop() }
                if let w = obj as? WindowWatcher { w.stop() }
                if let w = obj as? AFKWatcher { w.stop() }
                if let w = obj as? MouseTracker { w.stop() }
                if let w = obj as? InputWatcher { w.stop() }
                if let w = obj as? GitWatcher { w.stop() }
                if let w = obj as? ObsidianWatcher { w.stop() }
            }
            for t in keepAliveTimers { t.invalidate() }
            print("Cleanup complete. Goodbye.")
            Darwin.exit(0)
        }
        signal(SIGINT) { sig in
            print("\nUseTrack Collector interrupted (signal \(sig))...")
            Darwin.exit(0)
        }

        // Keep the process alive
        RunLoop.current.run()
    }

    /// Check if Screen Recording permission is granted by inspecting window titles.
    /// Without permission, CGWindowListCopyWindowInfo returns windows but with empty titles.
    private static func checkScreenRecordingPermission() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        // If we can read at least one window title, permission is granted
        return windowList.contains { info in
            if let name = info[kCGWindowName as String] as? String, !name.isEmpty {
                return true
            }
            return false
        }
    }
}
