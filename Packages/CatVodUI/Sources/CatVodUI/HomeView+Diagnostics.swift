import SwiftUI

// 发现页的**诊断件**（M28 首验之二十九）：`scrollTouchObserver` / `.refreshable` 的「挂 / 不挂」
// 开关，服务 ``CardDiagnostics`` 的隔离实验。单拆一个文件：`HomeView` 的类型体贴着
// SwiftLint `type_body_length` 的 error 线（450），诊断件不该占它的额度。

/// 诊断用：`scrollTouchObserver` 的「挂 / 不挂」开关（`ViewModifier` 形式，条件为假时不改任何东西）。
private struct ScrollTouchObserverModifier: ViewModifier {
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
private struct RefreshableModifier: ViewModifier {
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
