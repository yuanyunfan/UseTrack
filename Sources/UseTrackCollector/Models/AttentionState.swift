// UseTrack — macOS Activity Tracker
// AttentionState: 注意力状态枚举，用于多屏场景下判定用户对各窗口的关注程度

import Foundation

/// 注意力状态等级，从高到低:
/// - activeFocus: 用户正在主动操作的窗口（前台 + 键鼠输入）
/// - activeReference: 用户可见且近期交互过（如第二屏的参考文档）
/// - passiveVisible: 可见但未交互（如后台播放的视频）
/// - stale: 已不可见或长时间未交互
enum AttentionState: String, Codable, Sendable {
    case activeFocus
    case activeReference
    case passiveVisible
    case stale
}
