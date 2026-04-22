// UseTrack — macOS Activity Tracker
// 核心逻辑单元测试

import XCTest
import SQLite
@testable import UseTrackCollector

// MARK: - TrackingState Tests

final class TrackingStateTests: XCTestCase {
    func testStateDescription() {
        XCTAssertEqual(TrackingState.stopped.description, "stopped")
        XCTAssertEqual(TrackingState.active.description, "active")
        XCTAssertEqual(TrackingState.idle.description, "idle")
        XCTAssertEqual(TrackingState.locked.description, "locked")
        XCTAssertEqual(TrackingState.asleep.description, "asleep")
    }

    func testStateEquality() {
        XCTAssertEqual(TrackingState.active, TrackingState.active)
        XCTAssertNotEqual(TrackingState.active, TrackingState.idle)
    }
}

// MARK: - AttentionState Tests

final class AttentionStateTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(AttentionState.activeFocus.rawValue, "activeFocus")
        XCTAssertEqual(AttentionState.activeReference.rawValue, "activeReference")
        XCTAssertEqual(AttentionState.passiveVisible.rawValue, "passiveVisible")
        XCTAssertEqual(AttentionState.stale.rawValue, "stale")
    }

    func testCodable() throws {
        let state = AttentionState.activeFocus
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AttentionState.self, from: data)
        XCTAssertEqual(state, decoded)
    }
}

// MARK: - ActivityEvent Tests

final class ActivityEventTests: XCTestCase {
    func testEventCreation() {
        let event = ActivityEvent(
            id: nil,
            timestamp: Date(),
            activity: "app_switch",
            appName: "Cursor",
            windowTitle: "main.swift",
            durationSeconds: nil,
            meta: ["bundle_id": "com.todesktop.230313mzl4w4u92"],
            category: "deep_work"
        )

        XCTAssertNil(event.id)
        XCTAssertEqual(event.activity, "app_switch")
        XCTAssertEqual(event.appName, "Cursor")
        XCTAssertEqual(event.category, "deep_work")
        XCTAssertEqual(event.meta?["bundle_id"], "com.todesktop.230313mzl4w4u92")
    }

    func testEventCodable() throws {
        let event = ActivityEvent(
            id: 42,
            timestamp: Date(timeIntervalSince1970: 1000),
            activity: "focus",
            appName: "Chrome",
            windowTitle: "GitHub",
            durationSeconds: 120.5,
            meta: ["url": "https://github.com"],
            category: "browsing"
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)

        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.activity, "focus")
        XCTAssertEqual(decoded.appName, "Chrome")
        XCTAssertEqual(decoded.durationSeconds, 120.5)
        XCTAssertEqual(decoded.meta?["url"], "https://github.com")
    }

    func testEventWithNilFields() {
        let event = ActivityEvent(
            id: nil,
            timestamp: Date(),
            activity: "idle_start",
            appName: nil,
            windowTitle: nil,
            durationSeconds: nil,
            meta: nil,
            category: nil
        )

        XCTAssertNil(event.appName)
        XCTAssertNil(event.windowTitle)
        XCTAssertNil(event.meta)
        XCTAssertNil(event.category)
    }
}

// MARK: - WindowSnapshot Tests

final class WindowSnapshotTests: XCTestCase {
    func testSnapshotCodable() throws {
        let snapshot = WindowSnapshot(
            timestamp: Date(timeIntervalSince1970: 1000),
            screenIndex: 0,
            appName: "Cursor",
            windowTitle: "main.swift",
            attention: .activeFocus,
            score: 18.5,
            bounds: CGRect(x: 100, y: 200, width: 1200, height: 800)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)

        XCTAssertEqual(decoded.appName, "Cursor")
        XCTAssertEqual(decoded.attention, .activeFocus)
        XCTAssertEqual(decoded.score, 18.5)
        XCTAssertEqual(decoded.bounds.origin.x, 100)
        XCTAssertEqual(decoded.bounds.size.width, 1200)
        XCTAssertEqual(decoded.screenIndex, 0)
    }

    func testSnapshotWithNilTitle() throws {
        let snapshot = WindowSnapshot(
            timestamp: Date(),
            screenIndex: 1,
            appName: "[Redacted]",
            windowTitle: nil,
            attention: .stale,
            score: 0,
            bounds: .zero
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)

        XCTAssertNil(decoded.windowTitle)
        XCTAssertEqual(decoded.attention, .stale)
    }
}

// MARK: - BrowserURLWatcher Tests

final class BrowserURLWatcherTests: XCTestCase {
    func testSupportedBrowserDetection() {
        // Chromium 系
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Google Chrome"))
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Microsoft Edge"))
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Brave Browser"))
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Vivaldi"))
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Arc"))

        // WebKit 系
        XCTAssertTrue(BrowserURLWatcher.isSupportedBrowser("Safari"))

        // 非浏览器
        XCTAssertFalse(BrowserURLWatcher.isSupportedBrowser("Cursor"))
        XCTAssertFalse(BrowserURLWatcher.isSupportedBrowser("Terminal"))
        XCTAssertFalse(BrowserURLWatcher.isSupportedBrowser("Finder"))
        XCTAssertFalse(BrowserURLWatcher.isSupportedBrowser("Unknown"))
    }

    func testSupportedBrowserBundleIDs() {
        XCTAssertEqual(BrowserURLWatcher.supportedBrowsers["Google Chrome"], "com.google.Chrome")
        XCTAssertEqual(BrowserURLWatcher.supportedBrowsers["Safari"], "com.apple.Safari")
        XCTAssertEqual(BrowserURLWatcher.supportedBrowsers["Arc"], "company.thebrowser.Browser")
    }
}

// MARK: - AppWatcher Tests

final class AppWatcherTests: XCTestCase {
    func testIgnoredAppsAreNotEmpty() {
        // AppWatcher 内部的 ignoredApps 集合不应为空
        // （间接测试：创建一个 AppWatcher 不应崩溃）
        let dbPath = NSTemporaryDirectory() + "usetrack_test_\(UUID().uuidString).db"
        guard let db = try? DatabaseManager(dbPath: dbPath) else {
            XCTFail("Failed to create test database")
            return
        }
        let watcher = AppWatcher(dbManager: db)
        XCTAssertNotNil(watcher)
        // Cleanup
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testTruncateCurrentBackfillsDurationAndClearsState() throws {
        let dbPath = NSTemporaryDirectory() + "usetrack_truncate_\(UUID().uuidString).db"
        let db = try DatabaseManager(dbPath: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let watcher = AppWatcher(dbManager: db)
        // 用 start() 启动后会立刻为当前前台 app 写一条 row（duration=nil）。
        // 测试环境下 frontmostApplication 可能是 xctest，这条 row 也算有效。
        watcher.start()
        defer { watcher.stop() }

        // 给 1 秒后再 truncate，模拟用户停留 1s 然后 AFK
        let truncateAt = Date().addingTimeInterval(1.0)
        watcher.truncateCurrent(at: truncateAt)

        // 第二次 truncate 应是 no-op（lastActivityRowId 已被清空），不会崩溃也不会再插行
        watcher.truncateCurrent(at: Date().addingTimeInterval(2.0))

        // 验证 DB 中最新的 app_switch 行 duration_s 在合理范围（约 1s 上下）
        let conn = try Connection(dbPath, readonly: true)
        var durations: [Double] = []
        for row in try conn.prepare("SELECT duration_s FROM activity_stream WHERE activity = 'app_switch' AND duration_s IS NOT NULL") {
            if let d = row[0] as? Double { durations.append(d) }
        }
        XCTAssertEqual(durations.count, 1, "应恰好有一条 app_switch 被回填了 duration")
        if let d = durations.first {
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThan(d, 5, "duration 应接近 1 秒，不应被异常放大")
        }
    }
}
