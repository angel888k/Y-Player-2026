import Foundation
import os

/// 冷启动的**分段计时**日志（M28P9）：慢在哪一段，一条命令取全部。
///
/// 为什么需要它：用户报「接口已经导入过，冷启动加载感觉有点慢」—— 这一路要过的坎有好几段
/// （读配置 → 起内嵌 Node 宿主 → 取站点清单 → 首页数据），**每段都可能慢，界面上只表现为一个转圈**。
/// 先把每段的用时记下来，再谈优化；没有这几行就只能猜。
///
///     xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep 启动
///
/// 与 `ImageLoadTrace` / `PlaybackTrace` 同一套：子系统 = App 的 bundle id，级别 `.notice`。
enum StartupTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "startup")

    /// 冷启动的起点（**只记第一次**：回前台 / 手动加载不会再把它推后）。
    nonisolated(unsafe) private static var startedAt: Date?

    /// 记下起点（幂等）。
    static func begin() {
        guard startedAt == nil else {
            return
        }
        startedAt = Date()
    }

    /// 记一段：`启动：<段名> 累计 <ms>ms（附注）`（毫秒从 ``begin()`` 那刻算起）。
    ///
    /// - Parameter detail: 附注（站点数 / 是否用缓存…）—— 直接拼进日志，别塞隐私内容。
    static func note(_ stage: String, detail: String = "") {
        let now = Date()
        guard let startedAt else {
            logger.notice("启动：\(stage, privacy: .public)（没有起点，只此一条）\(suffix(detail))")
            return
        }
        let total = Int(now.timeIntervalSince(startedAt) * 1000)
        logger.notice(
            "启动：\(stage, privacy: .public) 累计 \(total)ms\(suffix(detail))"
        )
    }

    private static func suffix(_ detail: String) -> String {
        detail.isEmpty ? "" : "（\(detail)）"
    }
}
