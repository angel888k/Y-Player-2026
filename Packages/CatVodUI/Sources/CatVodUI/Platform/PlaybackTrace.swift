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

    /// 一次点按：单击还是双击、落点、按设置该走哪一区、解析出的动作；被吞掉的那种也记（动作写「（被吞）」）。
    static func noteTap(
        doubleTap: Bool,
        location: CGPoint?,
        isCenter: Bool,
        action: String
    ) {
        let point = location.map { "(\(Int($0.x.rounded())), \(Int($0.y.rounded())))" } ?? "无"
        logger.notice(
            "点按 \(doubleTap ? "双击" : "单击", privacy: .public)"
                + " 落点 \(point, privacy: .public)"
                + "／分区 \(isCenter ? "中间" : "两边", privacy: .public)"
                + "／动作 \(action, privacy: .public)"
        )
    }

    /// 长按加速：起 / 收 / 自愈（「挂太久」被收掉）。
    static func noteBoost(_ event: String) {
        logger.notice("长按加速 \(event, privacy: .public)")
    }

    /// 控制条显隐：谁改的、改成什么。
    static func noteControls(visible: Bool, reason: String) {
        logger.notice("控制条 \(visible ? "显示" : "收起", privacy: .public)：\(reason, privacy: .public)")
    }
}
