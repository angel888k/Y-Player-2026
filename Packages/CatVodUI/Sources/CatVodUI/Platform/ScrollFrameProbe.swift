import Foundation
import os
import QuartzCore

/// 滚动帧探针（M28 首验之二十九）：拖动期间统计**实际帧间隔**，松手出一条日志。
///
/// 为什么不用 `CADisplayLink`：模拟器里它**根本不 tick**（上机抓过：`开始记账` 有、样本恒为 0）。
/// 改用滚动自身的节拍：`dragChanged` 每个渲染帧来一次 —— 它**相邻两次的间隔**就是帧间隔
/// （间隔变大 = 卡了一帧），而且这条信号在模拟器里一定存在。
///
/// 与 ``ImageLoadTrace`` 同一套：子系统 = App 的 bundle id、级别 `.notice`。
///
///     xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep 滚动帧
///
/// 只在**模拟器**上开；真机观感以用户为准。
@MainActor
final class ScrollFrameProbe {
    private var lastTick: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var intervals: [Double] = []

    /// 手指碰上屏幕：开始记账。
    func begin() {
        #if targetEnvironment(simulator)
        intervals.removeAll(keepingCapacity: true)
        startedAt = CACurrentMediaTime()
        lastTick = startedAt
        #endif
    }

    /// 每帧一次（挂在外层滚动的 `onDragChanged` 上）。
    func tick() {
        #if targetEnvironment(simulator)
        let now = CACurrentMediaTime()
        let delta = now - lastTick
        lastTick = now
        // 只在手势头两帧的 gap 会混进「开始记账 → 第一帧」的距离，剔掉明显异常的样本。
        if delta > 0, delta < 0.5 {
            intervals.append(delta)
        }
        #endif
    }

    /// 松手：结算一条日志（带拖动时长 —— 「样本少」要能分出「拖得短」还是「回调没来」）。
    func end() {
        #if targetEnvironment(simulator)
        let dragMs = Int((CACurrentMediaTime() - startedAt) * 1000)
        guard !intervals.isEmpty else {
            FrameProbeTrace.noteEmpty(dragMs: dragMs)
            return
        }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted[sorted.count - 1]
        let slow = intervals.filter { $0 > 0.024 }.count
        FrameProbeTrace.note(
            frames: intervals.count,
            dragMs: dragMs,
            medianMs: Int(median * 1000),
            worstMs: Int(worst * 1000),
            slowFrames: slow
        )
        intervals.removeAll(keepingCapacity: true)
        #endif
    }
}

/// 帧探针日志（滚动期间一条）。
enum FrameProbeTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "frame")

    /// 开始记账（拖动真的被我们看到了才会出现 —— 没有这条 = 那条触摸回调没来）。
    static func noteBegan() {
        logger.notice("滚动帧：开始记账")
    }

    /// 松手但一个采样都没有（拖动短，或者拖动回调没来 —— 带着拖动时长看）。
    static func noteEmpty(dragMs: Int) {
        logger.notice("滚动帧：这次拖动没有采到样本（拖动 \(dragMs) ms）")
    }

    /// 一条滚动结束时的帧账。
    static func note(frames: Int, dragMs: Int, medianMs: Int, worstMs: Int, slowFrames: Int) {
        logger.notice(
            "滚动帧：\(frames) 帧（拖动 \(dragMs) ms）· 中位 \(medianMs) ms · 最慢 \(worstMs) ms · 超 24ms \(slowFrames) 帧"
        )
    }
}
