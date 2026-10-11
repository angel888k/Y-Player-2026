import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 平台差异 shim：把 iOS 15 / macOS 13 的差异集中在这里，业务代码不做散落的 `#if`。
public enum PlatformShims {
    /// 复制到系统剪贴板。
    ///
    /// iOS 与 macOS 的 API 完全不同，**只在这一处知道这件事**（业务代码不做 `#if`）。
    /// 诊断报告（M17P1）靠它把一段纯文本交给用户 —— 模拟器与 Mac 的剪贴板是通的，
    /// 复制完直接在 Mac 上粘贴即可。
    @MainActor
    public static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// 屏幕亮度（0...1）；读不到就给 `nil`（macOS 没有公开 API、或拿不到前台窗口场景）。
    ///
    /// 谁在用：播放页「左半屏纵向拖 = 亮度」（M03P12）—— 拿不到就**整次拖动不做事**，
    /// 不摆一个「拖了没反应」的假手势。
    @MainActor
    public static func screenBrightness() -> Double? {
        #if os(iOS)
        guard let screen = activeScreen else {
            return nil
        }
        return Double(screen.brightness)
        #else
        return nil
        #endif
    }

    /// 设屏幕亮度（0...1）。iOS 改的是**系统亮度**（iOS 没有「App 内亮度」这回事 ——
    /// 上游改的是 activity 窗口亮度，那是 Android 才有的东西）；macOS 是空操作
    /// （`screenBrightness()` 会给 `nil`，调用方本来就不会走到这）。
    @MainActor
    public static func setScreenBrightness(_ value: Double) {
        #if os(iOS)
        guard let screen = activeScreen else {
            return
        }
        screen.brightness = CGFloat(min(max(value, 0), 1))
        #endif
    }

    /// 电量（0...1）与充没充电；读不到给 nil（模拟器不报 / iOS 之外的平台）。
    ///
    /// 谁在用：全屏播放控制条顶上的状态行（时钟 / 标题 / 电量，M28 首验之十四）——
    /// 读不到就**整截不画**（不写假话，与「拿不到的数据不显示」同一条规矩）。
    @MainActor
    public static func batteryStatus() -> (level: Double, charging: Bool)? {
        #if os(iOS)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled {
            // 打开监控才读得到电量（幂等；每次写一遍没必要）。
            device.isBatteryMonitoringEnabled = true
        }
        let level = Double(device.batteryLevel)
        guard level >= 0 else {
            return nil
        }
        let charging = device.batteryState == .charging || device.batteryState == .full
        return (level, charging)
        #else
        return nil
        #endif
    }

    /// 能不能请求屏幕方向（播放页那颗「旋转」，M26）。
    ///
    /// **只有 iOS 16+ 有公开 API**（`UIWindowScene.requestGeometryUpdate`）——
    /// iOS 15 与 macOS 拿不到：拿不到的系统上**这颗按钮就不出现**（UI 规范第 5 条：
    /// 没有公开 API 的能力不做，也不用私有 API 去凑）。
    public static var canRequestPlaybackOrientation: Bool {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// 现在是不是横屏；拿不到（macOS / 没有前台场景）给 `nil`。
    @MainActor
    public static func isPlaybackLandscape() -> Bool? {
        #if os(iOS)
        guard let scene = activeWindowScene else {
            return nil
        }
        return scene.interfaceOrientation.isLandscape
        #else
        return nil
        #endif
    }

    /// 请求转到横屏 / 竖屏；返回 `false` = 这个系统没有公开 API / 拿不到场景，调用方不做事。
    @MainActor
    @discardableResult
    public static func requestPlaybackOrientation(landscape: Bool) -> Bool {
        #if os(iOS)
        guard #available(iOS 16.0, *), let scene = activeWindowScene else {
            return false
        }
        // iOS 16 起系统会重新问一遍 `supportedInterfaceOrientations` —— SwiftUI 这边就这一个公开钩子。
        // **先请它更新、再提请求**（Apple 样例的顺序）：反过来容易拿到一份还没更新的支持集合，
        // 请求就被系统悄悄拒掉（M27 首验之六之六：日志里有一次转屏请求没落地）。
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
        return true
        #else
        return false
        #endif
    }

    #if os(iOS)
    /// 前台那个窗口场景（`UIScreen.main` 从 iOS 16 起被弃用，别用它）。
    @MainActor
    private static var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// 前台那个窗口场景的屏幕。
    @MainActor
    private static var activeScreen: UIScreen? {
        activeWindowScene?.screen
    }
    #endif

    /// 跨平台颜色（`Color` 在两平台同名，这里只留扩展点）。
    public static let accent = Color.accentColor

    /// 页面底色（iOS 的 `systemBackground` / macOS 的 `windowBackgroundColor`）。
    ///
    /// 谁在用：TMDB 头图的**底部融合渐变**（对齐参考的 Emby 视图）—— 图往「页面底色」融，
    /// 而不是往死黑融：深色外观下就是黑、浅色下是白，跟着系统走，不写死。
    public static var pageBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// 卡片圆角。
    public static let cardCornerRadius: CGFloat = 10
}

public extension View {
    /// 搜索框「永不自动首字母大写」。
    ///
    /// `textInputAutocapitalization` 是 **iOS-only**：直接写在视图里会让 macOS 编译不过（CI 就是这么红的）。
    /// 平台差异收敛到 shim —— 这是本仓库的规矩。`#if` 内按 `.swiftformat` 的 `--ifdef no-indent` 不额外缩进。
    func platformTextInputAutocapitalizationNever() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never)
        #else
        return self
        #endif
    }
}
