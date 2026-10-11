import CoreGraphics
import os

/// 画面宿主的**排障日志**（M27 首验之六起）：把「画面区给了多大、宿主被摆成多大、层多大」打进系统日志。
///
/// 为什么需要它：尺寸这一路的毛病（画面卡在旧槽位 / 点屏幕没反应 / 转屏后错位）都是**静默**的 ——
/// 屏幕上只表现为「黑着，画面在角落里」；而这些是界面接线，本机单测碰不到。
/// 出事时一条命令取全部（子系统就是 App 的 bundle id，与 `LibavTrace` 同一套）：
///
///     xcrun simctl spawn booted log show --last 5m --predicate 'subsystem == "com.YPlayer.cat"' --style compact
///
/// 插值一律标 `.public`：os_log 默认把值打码成 `<private>`，不标就等于白打。
/// **级别一律用 `.notice`（不是 `.debug`）**：debug 级默认**不落盘**，`log show` 根本查不到 ——
/// 首验之二就栽在这里（引擎那几条 `Df` 是 default 级，不是 debug；照抄它的级别会白打一遍）。
enum VideoHostTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "video-host")

    /// 宿主收到的画面区尺寸，与它最后的 `frame` / 层的 `frame`（只在尺寸真的变了时记）。
    static func noteHostSize(_ size: CGSize, frame: CGRect, layerFrame: CGRect?) {
        let requested = size.debugDescription
        let host = frame.debugDescription
        let layer = layerFrame?.debugDescription ?? "无"
        logger.notice("画面宿主：画面区 \(requested, privacy: .public)／宿主 \(host, privacy: .public)／层 \(layer, privacy: .public)")
    }

    /// 从宿主往上走的祖先链（谁被藏了 / 谁裁了 / 谁多小）——
    /// 「层几何全对、屏幕上却看不见」这种怪事只可能出在祖先里（M27 首验之六之八）。
    static func noteAncestors(_ text: String) {
        logger.notice("画面宿主祖先：\(text, privacy: .public)")
    }

    /// 宿主底色（品红探针在不在这个包里，一眼可见）。
    static func noteHostColor(_ text: String) {
        logger.notice("画面宿主底色：\(text, privacy: .public)")
    }

    /// 过一秒复查：**层还在宿主里吗、frame 还是我们设的那个吗**。
    ///
    /// 为什么值得查：「画面在自己窗口里、却缩在一角」还有另一种可能 —— **系统把层搬走了**
    /// （画中画：`AVPictureInPictureController` 起 PiP 时会把 `AVPlayerLayer` 挪进它自己的窗口，
    /// 我们就只剩一片黑），那跟尺寸一点关系都没有。这两项一列，两种可能就分得清。
    static func noteLayerCheck(
        attached: Bool,
        frame: CGRect?,
        layerBounds: CGRect?,
        presentationBounds: CGRect?,
        contentsGravity: String?,
        drawableSize: CGSize?,
        identityTransform: Bool?,
        windowFrame: CGRect?,
        windowSize: CGSize?
    ) {
        let state = attached ? "在" : "不在"
        let layer = frame?.debugDescription ?? "无"
        let bounds = layerBounds?.debugDescription ?? "无"
        let presenting = presentationBounds?.debugDescription ?? "无"
        let gravity = contentsGravity ?? "无"
        let transform = (identityTransform ?? true) ? "单位阵" : "被改过"
        let onScreen = windowFrame?.debugDescription ?? "不在窗口里"
        let window = windowSize?.debugDescription ?? "无窗口"
        logger.notice("画面宿主复查：层\(state, privacy: .public)宿主／frame \(layer, privacy: .public)")
        logger.notice("画面宿主复查：层 bounds \(bounds, privacy: .public)／transform \(transform, privacy: .public)")
        let drawable = drawableSize?.debugDescription ?? "无（不是 Metal 层）"
        logger.notice("画面宿主复查：**渲染中**的 bounds \(presenting, privacy: .public)／contentsGravity \(gravity, privacy: .public)")
        logger.notice("画面宿主复查：Metal 画布 \(drawable, privacy: .public)")
        logger.notice("画面宿主复查：宿主在窗口里 \(onScreen, privacy: .public)／窗口 \(window, privacy: .public)")
    }
}
