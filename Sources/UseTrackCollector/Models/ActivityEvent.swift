// UseTrack — macOS Activity Tracker
// ActivityEvent: 核心事件模型，记录用户的每一次活动状态变化

import Foundation

struct ActivityEvent: Codable, Sendable {
    /// 数据库自增主键，新建事件时为 nil
    let id: Int64?
    /// 事件发生的时间戳
    let timestamp: Date
    /// 活动类型: app_switch / url_visit / idle / typing / focus
    let activity: String
    /// 当前前台应用名称
    let appName: String?
    /// 当前窗口标题
    let windowTitle: String?
    /// 该状态持续的秒数
    let durationSeconds: Double?
    /// 扩展元数据 JSON: {url, project, file_path, keystrokes_per_min}
    let meta: [String: String]?
    /// 活动分类: deep_work / communication / browsing / entertainment
    let category: String?
}
