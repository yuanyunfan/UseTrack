// UseTrack — macOS Activity Tracker
// ScreenDetector: 检测所有屏幕和窗口位置信息，支持多屏场景
//
// 坐标系说明:
// - CGWindowList 使用 Core Graphics 坐标系（原点在主屏左上角，Y 轴向下）
// - NSScreen.frame 使用 Cocoa 坐标系（原点在主屏左下角，Y 轴向上）
// - 本模块统一使用 CG 坐标系，将 NSScreen.frame 转换后再与窗口 bounds 比较

import Foundation
import AppKit
import CoreGraphics

/// Information about a visible window on screen
struct VisibleWindow {
    let ownerPID: pid_t
    let appName: String
    let windowTitle: String?
    let bounds: CGRect           // Global coordinate position (CG coordinate system)
    let screenIndex: Int         // Which monitor (0 = primary)
    let layer: Int               // Window layer (0 = normal)
    let isOnScreen: Bool
}

/// Detects all screens and visible windows, maps windows to their screens.
class ScreenDetector {

    /// Get information about all connected screens.
    /// Returns frames converted to CG coordinate system (origin at top-left of main screen).
    func getScreens() -> [(index: Int, frame: CGRect, isMain: Bool)] {
        let screens = NSScreen.screens
        guard let mainScreen = screens.first(where: { $0 == NSScreen.main }) ?? screens.first else {
            return []
        }
        let mainHeight = mainScreen.frame.height

        return screens.enumerated().map { (index, screen) in
            let cgFrame = cocoaToCG(cocoaFrame: screen.frame, mainScreenHeight: mainHeight)
            return (index: index, frame: cgFrame, isMain: screen == NSScreen.main)
        }
    }

    /// Get all visible windows across all screens.
    /// Requires Screen Recording permission for full window titles.
    func getVisibleWindows() -> [VisibleWindow] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let screens = getScreens()

        return windowList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let appName = info[kCGWindowOwnerName as String] as? String,
                  let boundsRaw = info[kCGWindowBounds as String],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0  // Only normal windows (skip menu bar, dock, etc.)
            else { return nil }

            // Bridge through NSDictionary to get CFDictionary for CGRectMakeWithDictionaryRepresentation
            guard let boundsNS = boundsRaw as? NSDictionary else { return nil }
            let boundsDict = boundsNS as CFDictionary
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds) else {
                return nil
            }

            // Skip tiny windows (system UI elements)
            guard bounds.width > 50 && bounds.height > 50 else { return nil }

            let title = info[kCGWindowName as String] as? String
            let screenIndex = determineScreenIndex(windowBounds: bounds, screens: screens)
            let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? true

            return VisibleWindow(
                ownerPID: pid,
                appName: appName,
                windowTitle: title,
                bounds: bounds,
                screenIndex: screenIndex,
                layer: layer,
                isOnScreen: isOnScreen
            )
        }
    }

    /// Get the focused (frontmost) window.
    func getFocusedWindow() -> VisibleWindow? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let windows = getVisibleWindows()
        // Return the first window belonging to the frontmost app
        return windows.first { $0.ownerPID == frontApp.processIdentifier }
    }

    // MARK: - Private

    /// Convert Cocoa coordinate frame (origin bottom-left) to CG coordinate frame (origin top-left).
    ///
    /// Cocoa: y=0 at bottom of main screen, Y grows upward
    /// CG:   y=0 at top of main screen, Y grows downward
    ///
    /// Formula: cgY = mainScreenHeight - cocoaY - frameHeight
    private func cocoaToCG(cocoaFrame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        let cgY = mainScreenHeight - cocoaFrame.origin.y - cocoaFrame.height
        return CGRect(
            x: cocoaFrame.origin.x,
            y: cgY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    /// Determine which screen a window belongs to based on where its center point falls.
    /// Falls back to finding the screen with the most overlap area.
    private func determineScreenIndex(
        windowBounds: CGRect,
        screens: [(index: Int, frame: CGRect, isMain: Bool)]
    ) -> Int {
        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)

        // Find the screen that contains the window center
        for screen in screens {
            if screen.frame.contains(center) {
                return screen.index
            }
        }

        // Fallback: find screen with most overlap
        var bestOverlap: CGFloat = 0
        var bestIndex = 0
        for screen in screens {
            let intersection = windowBounds.intersection(screen.frame)
            if !intersection.isNull {
                let overlap = intersection.width * intersection.height
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = screen.index
                }
            }
        }

        return bestIndex
    }
}
