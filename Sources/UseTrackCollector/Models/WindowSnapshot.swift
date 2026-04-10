// UseTrack — macOS Activity Tracker
// WindowSnapshot: 窗口快照模型，记录某一时刻各窗口的注意力状态

import Foundation
import CoreGraphics

struct WindowSnapshot: Codable, Sendable {
    /// 快照时间戳
    let timestamp: Date
    /// 屏幕索引 (0 = 主屏)
    let screenIndex: Int
    /// 应用名称
    let appName: String
    /// 窗口标题（可能包含敏感信息）
    let windowTitle: String?
    /// 注意力状态
    let attention: AttentionState
    /// 注意力评分 (多信号融合得分)
    let score: Double
    /// 窗口位置和尺寸
    let bounds: CGRect

    // MARK: - Custom Codable for CGRect

    private enum CodingKeys: String, CodingKey {
        case timestamp, screenIndex, appName, windowTitle, attention, score
        case x, y, width, height
    }

    init(timestamp: Date, screenIndex: Int, appName: String, windowTitle: String?,
         attention: AttentionState, score: Double, bounds: CGRect) {
        self.timestamp = timestamp
        self.screenIndex = screenIndex
        self.appName = appName
        self.windowTitle = windowTitle
        self.attention = attention
        self.score = score
        self.bounds = bounds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        screenIndex = try c.decode(Int.self, forKey: .screenIndex)
        appName = try c.decode(String.self, forKey: .appName)
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        attention = try c.decode(AttentionState.self, forKey: .attention)
        score = try c.decode(Double.self, forKey: .score)
        let x = try c.decode(Double.self, forKey: .x)
        let y = try c.decode(Double.self, forKey: .y)
        let w = try c.decode(Double.self, forKey: .width)
        let h = try c.decode(Double.self, forKey: .height)
        bounds = CGRect(x: x, y: y, width: w, height: h)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(screenIndex, forKey: .screenIndex)
        try c.encode(appName, forKey: .appName)
        try c.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try c.encode(attention, forKey: .attention)
        try c.encode(score, forKey: .score)
        try c.encode(bounds.origin.x, forKey: .x)
        try c.encode(bounds.origin.y, forKey: .y)
        try c.encode(bounds.size.width, forKey: .width)
        try c.encode(bounds.size.height, forKey: .height)
    }
}
