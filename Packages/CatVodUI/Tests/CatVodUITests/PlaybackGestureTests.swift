@testable import CatVodPlayer
@testable import CatVodUI
import Foundation
import Testing

/// 播放页手势（M03P12）：拖动落在哪一项、纵向怎么换算、长按加速什么时候能开始。
///
/// `@MainActor`：`PlaybackView` 是 `@MainActor` 的，它的静态成员也在主 actor 上 ——
/// 不标就变成「从非隔离上下文引用主 actor 隔离的成员」（Swift 5 模式是警告，Swift 6 是错误）。
@Suite("播放页：手势换算与长按加速")
@MainActor
struct PlaybackGestureTests {
    @Test("横向主导：调进度（起点在左半屏也一样）")
    func horizontalSeek() {
        #expect(PlaybackView.dragMode(dx: 40, dy: 10, startX: 10, width: 400) == .seek)
        #expect(PlaybackView.dragMode(dx: -40, dy: 10, startX: 390, width: 400) == .seek)
    }

    @Test("纵向主导：左半屏亮度、右半屏音量；中线算右半屏")
    func verticalSides() {
        #expect(PlaybackView.dragMode(dx: 0, dy: -60, startX: 10, width: 400) == .brightness)
        #expect(PlaybackView.dragMode(dx: 0, dy: -60, startX: 300, width: 400) == .volume)
        #expect(PlaybackView.dragMode(dx: 0, dy: -60, startX: 200, width: 400) == .volume)
    }

    @Test("斜着拖：哪边分量大听哪边")
    func diagonal() {
        #expect(PlaybackView.dragMode(dx: 60, dy: 40, startX: 10, width: 400) == .seek)
        #expect(PlaybackView.dragMode(dx: 40, dy: 60, startX: 10, width: 400) == .brightness)
        #expect(PlaybackView.dragMode(dx: 40, dy: 60, startX: 390, width: 400) == .volume)
    }

    @Test("纵向换算：向上加、向下减，200pt 走满量程，夹在 0...1")
    func verticalValue() {
        #expect(PlaybackView.verticalValue(base: 0.5, dy: -100, pointsForFullRange: 200) == 1.0)
        #expect(PlaybackView.verticalValue(base: 0.5, dy: 100, pointsForFullRange: 200) == 0.0)
        #expect(abs(PlaybackView.verticalValue(base: 0.5, dy: -20, pointsForFullRange: 200) - 0.6) < 1e-9)
        // 再往上拖也不越界（亮度到 1 就到头了）
        #expect(PlaybackView.verticalValue(base: 0.95, dy: -100, pointsForFullRange: 200) == 1.0)
        #expect(PlaybackView.verticalValue(base: 0.05, dy: 100, pointsForFullRange: 200) == 0.0)
    }

    @Test("横向换算：拖满一屏宽 ≈ 120 秒，夹在 0...总时长")
    func seekTarget() {
        #expect(PlaybackView.seekTarget(base: 60, dx: 200, width: 400, duration: 600) == 120)
        #expect(PlaybackView.seekTarget(base: 10, dx: -200, width: 400, duration: 600) == 0)
        #expect(PlaybackView.seekTarget(base: 590, dx: 200, width: 400, duration: 600) == 600)
    }

    @Test("双指缩放：倍数夹在 1.0–5.0（捏回 1.0 就是归位）")
    func zoomValue() {
        #expect(PlaybackView.zoomMaximum == 5)
        #expect(PlaybackView.zoomValue(base: 1, magnification: 2) == 2)
        #expect(PlaybackView.zoomValue(base: 2, magnification: 3) == 5)
        #expect(PlaybackView.zoomValue(base: 4, magnification: 0.25) == 1)
        #expect(PlaybackView.zoomValue(base: 1, magnification: 0.5) == 1)
    }

    @Test("长按加速的守卫：只在「正在播 + 还没在加速」时开始（上游同款）")
    func boostGuard() {
        #expect(PlaybackView.canStartSpeedBoost(isPlaying: true, isBoosting: false))
        #expect(!PlaybackView.canStartSpeedBoost(isPlaying: false, isBoosting: false))
        #expect(!PlaybackView.canStartSpeedBoost(isPlaying: true, isBoosting: true))
    }

    @Test("长按倍速：三条时间线是本项目的常量（M28 首验之八：长按线提到 1.5 秒）")
    func boostConstants() {
        #expect(SpeedSetting.longPress == 2.0)
        // 1.5：用户真实的「单击」实测按下 0.8–1.2 秒（日志反推）—— 这条线要躲开它，不是反过来。
        #expect(PlaybackView.speedBoostHoldSeconds == 1.5)
        #expect(PlaybackView.speedBoostSwallowSeconds == 0.5)
        // 3.5：真·长按可以按很久 —— 这条窗只兜「压根没有点按来」的挂死。
        #expect(PlaybackView.speedBoostTrustSeconds == 3.5)
        // 长按线要高于用户实测的单击（1.2 秒是有据可依的下限）。
        #expect(PlaybackView.speedBoostHoldSeconds >= 1.2)
        #expect(PlaybackView.speedBoostTrustSeconds > PlaybackView.speedBoostHoldSeconds)
        #expect(PlaybackView.speedBoostTrustSeconds > PlaybackView.speedBoostSwallowSeconds)
    }

    @Test("点按的分档（M28 首验之八）：长按的尾巴吞、挂太久自愈；尾巴晚于松手时看按住时长")
    func tapDisposition() {
        let now = Date()
        // 还在「按着」= 真·长按（长按线 1.5 秒，用户单击够不着）的尾巴：吞。
        #expect(PlaybackView.tapDisposition(
            isHolding: true, holdStartedAt: now.addingTimeInterval(-2.0), endedAt: nil, now: now
        ) == .swallow)
        // 「还按着」挂太久（≥ 信任窗）：自愈（先收加速再放行）。
        #expect(PlaybackView.tapDisposition(
            isHolding: true, holdStartedAt: now.addingTimeInterval(-30), endedAt: nil, now: now
        ) == .endStaleBoost)
        #expect(PlaybackView.tapDisposition(
            isHolding: true, holdStartedAt: nil, endedAt: nil, now: now
        ) == .endStaleBoost)
        // 松手先被识别、尾巴点按随后到（日志里两个方向都出现过）：按住 1.2 秒（够不着长按线，
        // 也就是说本来就没起加速）放行；按住 2.2 秒（真·长按）吞。
        #expect(PlaybackView.tapDisposition(
            isHolding: false,
            holdStartedAt: now.addingTimeInterval(-1.4),
            endedAt: now.addingTimeInterval(-0.2),
            now: now
        ) == .allow)
        #expect(PlaybackView.tapDisposition(
            isHolding: false,
            holdStartedAt: now.addingTimeInterval(-2.4),
            endedAt: now.addingTimeInterval(-0.2),
            now: now
        ) == .swallow)
        // 拿不到起点时退回老规矩：只认「刚松手」那个时间窗；窗口外放行。
        #expect(PlaybackView.tapDisposition(
            isHolding: false, holdStartedAt: nil, endedAt: now.addingTimeInterval(-0.2), now: now
        ) == .swallow)
        #expect(PlaybackView.tapDisposition(
            isHolding: false, holdStartedAt: nil, endedAt: now.addingTimeInterval(-5), now: now
        ) == .allow)
        #expect(PlaybackView.tapDisposition(
            isHolding: false, holdStartedAt: nil, endedAt: nil, now: now
        ) == .allow)
    }
}
