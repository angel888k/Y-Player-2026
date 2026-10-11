import os
import SwiftUI

/// 卡片形态的诊断开关（M28 首验之二十九）：**只为定位滚动卡顿**，一次构建、现场切换三种形态，
/// 看哪一档顺、哪一档卡 —— 比「改一版、构建一轮、猜一次」快得多。
///
/// 只在模拟器（`#if targetEnvironment(simulator)`）打开；真机 / 正式包里 `isEnabled` 恒为 false，
/// 开关按钮不出现、代码路径也走不到。
/// 线程约定：**只在主线程用**（`RootView` 放一份、视图读、按钮切）。
/// 类本身不标 `@MainActor` 是**故意的**：`EnvironmentKey.defaultValue` 是同步非隔离上下文，
/// 带隔离的 `init()` 在那儿建不了（上机编译抓过）。
final class CardDiagnostics: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        /// 现状：图 + 导航链接。
        case normal
        /// 纯色块（**不带图**）：顺 → 病在图片渲染/解码；卡 → 病在布局或滚动本身。
        case plain
        /// 不带 `NavigationLink`（图照常）：顺 → 病在导航链接的代价。
        case noLink
        /// **极简对照组**：整页换成一个最朴素的懒网格（200 个纯色格，无图无监听无导航）——
        /// 它也卡 → 病不在我们的页面内容，而在滚动容器本身或模拟器环境。
        case control
        /// 去掉**滚动监听器**（`scrollTouchObserver`）：它每帧改 `@State`、整页重建的头号嫌疑。
        case noObserver
        /// 去掉 `refreshable`（下拉刷新）。
        case noRefresh

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .normal: "现状"
            case .plain: "纯色块"
            case .noLink: "无导航链接"
            case .control: "极简对照"
            case .noObserver: "去监听器"
            case .noRefresh: "去下拉刷新"
            }
        }
    }

    @Published var mode: Mode = .normal

    /// 诊断是否可用（模拟器才有意义；真机不显示开关）。
    static var isEnabled: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// 工具栏图标角上的短标（1/2/3）。
    var modeShortLabel: String {
        switch mode {
        case .normal: "1"
        case .plain: "2"
        case .noLink: "3"
        case .control: "4"
        case .noObserver: "5"
        case .noRefresh: "6"
        }
    }

    /// 切到下一档（工具栏那颗按钮）。主线程上下文里改状态并落日志。
    func cycle() {
        Task { @MainActor in
            let all = Mode.allCases
            let next = (all.firstIndex(of: mode).map { $0 + 1 } ?? 0) % all.count
            mode = all[next]
            cardDiagLogger.notice("卡片诊断模式：\(self.mode.displayName, privacy: .public)")
        }
    }
}

private let cardDiagLogger = Logger(subsystem: "com.YPlayer.cat", category: "frame")

private struct CardDiagnosticsKey: EnvironmentKey {
    static let defaultValue = CardDiagnostics()
}

extension EnvironmentValues {
    /// 要有 **setter**：`.environment(_:_:)` 要的是可写键路径（与 `cachedImageLoader` 同一个写法，
    /// 少了 setter 编译器报「cannot convert KeyPath to WritableKeyPath」）。
    var cardDiagnostics: CardDiagnostics {
        get { self[CardDiagnosticsKey.self] }
        set { self[CardDiagnosticsKey.self] = newValue }
    }
}
