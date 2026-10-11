import SwiftUI

// 发现页的**诊断件**（M28 首验之二十九）：`scrollTouchObserver` / `.refreshable` 的「挂 / 不挂」
// 开关，服务 ``CardDiagnostics`` 的隔离实验。单拆一个文件：`HomeView` 的类型体贴着
// SwiftLint `type_body_length` 的 error 线（450），诊断件不该占它的额度。

/// 诊断用：`scrollTouchObserver` 的「挂 / 不挂」开关（`ViewModifier` 形式，条件为假时不改任何东西）。
struct ScrollTouchObserverModifier: ViewModifier {
    let isEnabled: Bool
    let onTouchDown: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onTouchEnded: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.scrollTouchObserver(
                onTouchDown: onTouchDown,
                onDragChanged: onDragChanged,
                onTouchEnded: onTouchEnded
            )
        } else {
            content
        }
    }
}

/// 诊断用：`.refreshable` 的「挂 / 不挂」开关。
struct RefreshableModifier: ViewModifier {
    let isEnabled: Bool
    let action: () async -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.refreshable {
                await action()
            }
        } else {
            content
        }
    }
}

/// 重建计数（诊断）：`scrollBody` 的**内容**每次被求值就 +1；一次拖动结束出一条账。
///
/// 用途：验证「滑动收 Tab 栏」那条线到底有没有把 `HomeView` 的滚动内容拉进每帧重建 ——
/// 数字是「一次拖动里内容重建了几次」与「门广播了几次」。无重建 + 仍卡 → 病不在重建。
enum ScrollRebuildCounter {
    /// 计数（静态：`@State` 的实例会被每次求值的新实例顶掉，实例计数不可靠）。
    nonisolated(unsafe) private static var count = 0

    static func noteRebuild() {
        count += 1
    }

    static func begin() {
        count = 0
    }

    static func end(reason: String) {
        ScrollRebuildLog.note(rebuilds: count, reason: reason)
    }
}

/// 重建计数日志（一次拖动一条；`滚动帧` 之外的独立线）。
enum ScrollRebuildLog {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "frame")

    static func note(rebuilds: Int, reason: String) {
        logger.notice("滚动重建：内容求值 \(rebuilds) 次（\(reason, privacy: .public)）")
    }
}
