import CoreGraphics
import Foundation
import os

/// 播放页的**排障日志**（M28 首验之四起）：点按 / 长按加速 / 控制条显隐这几条链路的留痕。
///
/// 为什么需要它：「点屏幕没反应 + `2.0x` 常亮」这类问题的可能性不止一种 ——
/// 点按没触发 / 触发了但被「长按尾巴」吞掉 / 触发了但动作是「无」/ 长按序列被系统取消 ——
/// **屏幕上看起来一模一样**。一条日志把「哪一段断了」钉死，别再靠猜（与 `VideoHostTrace` 同一套做法）。
///
/// 级别一律 `.notice`：debug 级默认不落盘，`log show` 查不到（M27 首验踩过）。
/// 取法：
///
///     xcrun simctl spawn booted log show --last 5m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep playback
enum PlaybackTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "playback")

    /// 一次点按：单击还是双击、落点、按设置该走哪一区、解析出的动作；被吞掉的那种也记。
    ///
    /// 先拼成**一个显式的 `String`** 再交给 `logger`：把三元、`map`、多个 `+` 塞进一条
    /// `os_log` 插值里，类型检查器会原地罢工（首验就红在这儿 —— 与 `VodDetailView+Compact`
    /// 那次「三元 + 长表达式」同一类）。
    static func noteTap(
        doubleTap: Bool,
        location: CGPoint?,
        isCenter: Bool,
        action: String,
        held: TimeInterval? = nil
    ) {
        let kind: String = doubleTap ? "双击" : "单击"
        let point: String = location.map { "(\(Int($0.x.rounded())), \(Int($0.y.rounded())))" } ?? "无"
        let zone: String = isCenter ? "中间" : "两边"
        // 「距长按起」是判定的输入（吞 / 放都看它）：下一步排障不用再猜用户按了多久。
        let heldText: String = held.map { String(format: "距长按起 %.2fs", $0) } ?? "无长按"
        let text = "点按 " + kind + " 落点 " + point + "／分区 " + zone + "／动作 " + action + "／" + heldText
        logger.notice("\(text, privacy: .public)")
    }

    /// 长按加速：起 / 收 / 自愈（「挂太久」被收掉）。
    static func noteBoost(_ event: String) {
        logger.notice("长按加速 \(event, privacy: .public)")
    }

    /// 控制条显隐：谁改的、改成什么。
    static func noteControls(visible: Bool, reason: String) {
        let state: String = visible ? "显示" : "收起"
        logger.notice("控制条 \(state, privacy: .public)：\(reason, privacy: .public)")
    }
}
