import Foundation
import os

/// 聚合搜索一轮的**规模与用时**日志（M28P15）：搜了几个站点、回来几个、命中几个、墙钟多长。
///
/// 为什么需要它（用户问「搜索是并发搜索接口的所有站点吗」）：把口径钉在日志里 —— 「站点」是这一轮
/// **全部**实际参与的站点（不是只搜前几个）；「已回」追不上「站点」就说明有站点没轮到（总时长预算
/// 到点）或者还悬着。没有这几行就只能靠界面猜。
///
///     xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep 聚合搜索
///
/// 与 `StartupTrace` / `FrameProbeTrace` 同一套：子系统 = App 的 bundle id，级别 `.notice`。
enum SearchTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "search")

    /// 一轮搜索结束时的账：规模 / 回报 / 命中 / 墙钟（毫秒）。
    static func noteFinished(sites: Int, reported: Int, hitSites: Int, elapsedMs: Int) {
        logger.notice("聚合搜索：站点 \(sites) · 已回 \(reported) · 命中 \(hitSites) · 墙钟 \(elapsedMs)ms")
    }
}
