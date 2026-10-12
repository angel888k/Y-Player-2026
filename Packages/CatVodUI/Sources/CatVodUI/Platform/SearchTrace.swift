import Foundation
import os

/// 聚合搜索一轮的**规模与用时**日志（M28P15；M28P17 起带上口径常数与一圈的两个时刻）。
///
/// 两行：
/// - `聚合搜索：站点 N · 已回 M · 命中 K · 墙钟 T ms（并发 C · 单站≤X s）` —— 账 + **口径自证**
///   （括号里的常数就是当前构建的并发与单站超时：旧构建没有这一段，一眼分得出装没装上新版）；
/// - `聚合搜索·一圈：站点 N · 全部开搜 a ms · 末站回报 b ms` —— 队列何时排空、最后一个回报
///   何时到：`b - a` 是网络尾巴；`a` 偏大说明回填被主线程占住了（逐站回报刷墙太密）。
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

    /// 一轮搜索结束时的账：规模 / 回报 / 命中 / 墙钟（毫秒）+ 口径常数（并发 / 单站超时上限）。
    static func noteFinished(
        sites: Int,
        reported: Int,
        hitSites: Int,
        elapsedMs: Int,
        concurrency: Int,
        requestTimeoutSeconds: Int
    ) {
        logger.notice(
            "聚合搜索：站点 \(sites) · 已回 \(reported) · 命中 \(hitSites) · 墙钟 \(elapsedMs)ms（并发 \(concurrency) · 单站≤\(requestTimeoutSeconds)s）"
        )
    }

    /// 一圈搜索的两个时刻（毫秒，从这一圈开始算）：全部开搜（最后一个站点真正开搜）、
    /// 末站回报（最后一个回报收到）。拿不到（被取消 / 预算外）记 -1。
    static func noteRound(sites: Int, startedAllMs: Int?, receivedAllMs: Int?) {
        logger.notice(
            "聚合搜索·一圈：站点 \(sites) · 全部开搜 \(startedAllMs ?? -1)ms · 末站回报 \(receivedAllMs ?? -1)ms"
        )
    }
}
