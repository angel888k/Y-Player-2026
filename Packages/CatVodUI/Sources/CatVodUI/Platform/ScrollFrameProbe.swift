import Foundation
import os
import QuartzCore

/// 滚动帧探针（M28 首验之二十九）：手指拖动期间统计**实际帧间隔**，松手出一条日志。
///
/// 为什么需要它：用户报「滑动还是卡顿」，但「卡」是主观的、成因也看不清 —— 主线程被什么占着
/// （同步解码？布局？还是动画与滚动打架）必须用帧账说话，不能靠猜。与 ``ImageLoadTrace`` 同一套：
/// 子系统 = App 的 bundle id、级别 `.notice`。
///
///     xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep 滚动帧
///
/// 只在**模拟器**上开（真机编译找不到 `targetEnvironment(simulator)` 就不生效）：
/// 真机观感对不对以用户为准，这里要的是「模拟器上量得出来」。
@MainActor
final class ScrollFrameProbe {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []

    /// 手指碰上屏幕：开始记账。
    func begin() {
        #if targetEnvironment(simulator)
        intervals.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        guard link == nil else {
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        #endif
    }

    /// 松手：结算一条日志（样本太少就不出，免得刷没用的行）。
    func end() {
        #if targetEnvironment(simulator)
        link?.invalidate()
        link = nil
        guard !intervals.isEmpty else {
            return
        }
        // 取中位与最慢一帧（平均会被「偶尔一帧 100ms」抹平，中位看常态）。
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted[sorted.count - 1]
        let slow = intervals.filter { $0 > 24 }.count
        FrameProbeTrace.note(
            frames: intervals.count,
            medianMs: Int(median * 1000),
            worstMs: Int(worst * 1000),
            slowFrames: slow
        )
        intervals.removeAll(keepingCapacity: true)
        #endif
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else {
            return
        }
        intervals.append(link.timestamp - lastTimestamp)
    }
}

/// 帧探针日志（滚动期间一条）。
enum FrameProbeTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "frame")

    static func note(frames: Int, medianMs: Int, worstMs: Int, slowFrames: Int) {
        logger.notice(
            "滚动帧：\(frames) 帧 · 中位 \(medianMs) ms · 最慢 \(worstMs) ms · 超 24ms \(slowFrames) 帧"
        )
    }
}
