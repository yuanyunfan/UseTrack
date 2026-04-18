// UseTrack — macOS Activity Tracker
// TrackingEngine: 统一状态机，管理所有 Watcher 的生命周期
//
// 设计参考 Gecko 项目的 TrackingState，解决 UseTrack 分散式状态管理的问题：
// - 所有系统状态（活跃/空闲/锁屏/睡眠）显式建模为 enum
// - 状态转换通过 transition(to:) 集中处理
// - 锁屏/睡眠时暂停昂贵的轮询（WindowWatcher、AttentionScorer）
// - 空闲时降低 WindowWatcher 轮询频率

import Foundation
import AppKit

/// 系统追踪状态
enum TrackingState: Equatable, CustomStringConvertible {
    case stopped   // 引擎未启动
    case active    // 用户活跃使用中
    case idle      // 空闲超过阈值
    case locked    // 屏幕锁定
    case asleep    // 系统睡眠

    var description: String {
        switch self {
        case .stopped: return "stopped"
        case .active:  return "active"
        case .idle:    return "idle"
        case .locked:  return "locked"
        case .asleep:  return "asleep"
        }
    }
}

/// 统一的追踪引擎，管理所有 Watcher 的启停和系统状态转换。
///
/// 状态转换图:
/// ```
///   stopped → active ↔ idle
///                ↕       ↕
///             locked ← ─ ┘
///                ↕
///             asleep
/// ```
class TrackingEngine {
    private(set) var state: TrackingState = .stopped

    // Watcher 引用（由外部传入）
    private let appWatcher: AppWatcher
    private let windowWatcher: WindowWatcher
    private let afkWatcher: AFKWatcher
    private let inputWatcher: InputWatcher
    private let attentionScorer: AttentionScorer
    private let mouseTracker: MouseTracker
    private let displayWatcher: DisplayWatcher

    // 系统事件 observer tokens
    private var observers: [NSObjectProtocol] = []

    // 回调：状态变化通知
    var onStateChange: ((TrackingState, TrackingState) -> Void)?

    init(
        appWatcher: AppWatcher,
        windowWatcher: WindowWatcher,
        afkWatcher: AFKWatcher,
        inputWatcher: InputWatcher,
        attentionScorer: AttentionScorer,
        mouseTracker: MouseTracker,
        displayWatcher: DisplayWatcher
    ) {
        self.appWatcher = appWatcher
        self.windowWatcher = windowWatcher
        self.afkWatcher = afkWatcher
        self.inputWatcher = inputWatcher
        self.attentionScorer = attentionScorer
        self.mouseTracker = mouseTracker
        self.displayWatcher = displayWatcher
    }

    // MARK: - Public API

    /// 启动引擎：注册系统通知并转入 active 状态
    func start() {
        guard state == .stopped else { return }
        registerSystemObservers()
        transition(to: .active)
        print("[TrackingEngine] Started — state: active")
    }

    /// 停止引擎：清理所有 observer 并停止所有 Watcher
    func stop() {
        transition(to: .stopped)
        unregisterSystemObservers()
        print("[TrackingEngine] Stopped")
    }

    /// 由 AFKWatcher 调用：用户变为空闲
    func userDidBecomeIdle() {
        if state == .active {
            transition(to: .idle)
        }
    }

    /// 由 AFKWatcher 调用：用户回来
    func userDidBecomeActive() {
        if state == .idle {
            transition(to: .active)
        }
    }

    // MARK: - State Transition（核心）

    /// 集中处理所有状态转换及其副作用。
    /// 所有 Watcher 的启停逻辑都在这里，不分散到各处。
    private func transition(to newState: TrackingState) {
        let oldState = state
        guard oldState != newState else { return }
        state = newState

        switch (oldState, newState) {

        // ---- 启动 ----
        case (.stopped, .active):
            appWatcher.start()
            windowWatcher.start()
            afkWatcher.start()
            inputWatcher.start()
            mouseTracker.start()
            displayWatcher.start()

        // ---- 活跃 ↔ 空闲 ----
        case (.active, .idle):
            // 空闲时：暂停 WindowWatcher 的高频轮询（省电）
            // AppWatcher 保持运行（用户可能切 App 后放着）
            windowWatcher.stop()
            // InputWatcher 和 MouseTracker 保持运行（检测用户回来）

        case (.idle, .active):
            // 恢复 WindowWatcher
            windowWatcher.start()

        // ---- 锁屏 ----
        case (_, .locked):
            // 锁屏时暂停所有昂贵的轮询
            windowWatcher.stop()
            inputWatcher.stop()
            mouseTracker.stop()
            afkWatcher.stop()
            // AppWatcher 保持（NSWorkspace 通知在解锁后自动恢复）

        case (.locked, .active):
            windowWatcher.start()
            inputWatcher.start()
            mouseTracker.start()
            afkWatcher.start()

        // ---- 睡眠 ----
        case (_, .asleep):
            // 系统睡眠：全部暂停
            windowWatcher.stop()
            inputWatcher.stop()
            mouseTracker.stop()
            afkWatcher.stop()
            // AppWatcher 保持（NSWorkspace 通知在唤醒后自动恢复）

        case (.asleep, .active):
            windowWatcher.start()
            inputWatcher.start()
            mouseTracker.start()
            afkWatcher.start()

        // ---- 停止 ----
        case (_, .stopped):
            appWatcher.stop()
            windowWatcher.stop()
            afkWatcher.stop()
            inputWatcher.stop()
            mouseTracker.stop()
            displayWatcher.stop()

        default:
            print("[TrackingEngine] Unexpected transition: \(oldState) → \(newState)")
        }

        onStateChange?(oldState, newState)
        print("[TrackingEngine] \(oldState) → \(newState)")
    }

    // MARK: - System Event Observers

    private func registerSystemObservers() {
        let ws = NSWorkspace.shared
        let nc = ws.notificationCenter
        let dnc = DistributedNotificationCenter.default()

        // 屏幕锁定
        let lockObs = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.transition(to: .locked)
        }
        observers.append(lockObs)

        // 屏幕解锁
        let unlockObs = dnc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.transition(to: .active)
        }
        observers.append(unlockObs)

        // 系统睡眠
        let sleepObs = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.transition(to: .asleep)
        }
        observers.append(sleepObs)

        // 系统唤醒
        let wakeObs = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Delay slightly after wake to let lock/unlock notifications settle,
            // then query the actual screen lock state to avoid race conditions
            // where wake and unlock notifications arrive in unpredictable order.
            // See: Issue #78
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let self = self else { return }
                // If another notification already moved us out of .asleep, don't override
                guard self.state == .asleep else { return }
                let isLocked: Bool = {
                    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
                       let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
                        return locked
                    }
                    return false
                }()
                self.transition(to: isLocked ? .locked : .active)
            }
        }
        observers.append(wakeObs)
    }

    private func unregisterSystemObservers() {
        for obs in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        observers.removeAll()
    }
}
