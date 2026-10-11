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

    @Test("还看不清方向：给 nil（下一帧再定）—— 免得把「起手慢的滑动」定成调亮度 / 音量（M28 首验之九）")
    func ambiguousDirectionWaits() {
        #expect(PlaybackView.dragMode(dx: 30, dy: 25, startX: 10, width: 400) == nil)
        #expect(PlaybackView.dragMode(dx: -26, dy: 24, startX: 390, width: 400) == nil)
        // 门限是 1.25 倍：差一点点也还算看不清；过线就定。
        #expect(PlaybackView.dragMode(dx: 31, dy: 25, startX: 10, width: 400) == nil)
        #expect(PlaybackView.dragMode(dx: 32, dy: 25, startX: 10, width: 400) == .seek)
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

    @Test("长按倍速：时间线是本项目的常量（M28 首验之十：起加速自己计时，线还是 1.5 秒）")
    func boostConstants() {
        #expect(SpeedSetting.longPress == 2.0)
        // 1.5：用户真实的「单击」实测按下 0.8–1.2 秒（日志反推）—— 这条线要躲开它，不是反过来。
        #expect(PlaybackView.speedBoostHoldSeconds == 1.5)
        // 「按下」的报时门槛：几乎为零（0.01 秒）—— 它只负责报到，不负责判定。
        #expect(PlaybackView.speedBoostPressDetectSeconds <= 0.05)
    }

    @Test("按住「动了」的判定：超过抖动线就不算按住（与 maximumDistance 同一条线）")
    func pressMoved() {
        #expect(!PlaybackView.pressMoved(CGSize(width: 10, height: 0)))
        #expect(PlaybackView.pressMoved(CGSize(width: 11, height: 0)))
        #expect(!PlaybackView.pressMoved(CGSize(width: 0, height: -10)))
        #expect(PlaybackView.pressMoved(CGSize(width: 0, height: -11)))
        #expect(!PlaybackView.pressMoved(CGSize(width: 8, height: 8)))
        #expect(PlaybackView.pressMoved(CGSize(width: 8, height: 12)))
    }

    @Test("点按的分档（M28 首验之十）：只看量出来的按住时长 —— 0.45 秒的单击放行、2 秒的尾巴吞")
    func tapDisposition() {
        let now = Date()
        // 尾巴点按先到（松手还没被识别，`pressEndedAt` 还是 nil）：按住 0.45 秒的单击放行 ——
        // 现场日志里就是它被误吞过（「点屏幕没反应 / 按钮点了没动静」）。
        #expect(PlaybackView.tapDisposition(
            isHolding: true, pressStartedAt: now.addingTimeInterval(-0.45), pressEndedAt: nil, now: now
        ) == .allow)
        // 真·长按（按住 2 秒）的尾巴：吞（不让控制条闪）。
        #expect(PlaybackView.tapDisposition(
            isHolding: true, pressStartedAt: now.addingTimeInterval(-2.0), pressEndedAt: nil, now: now
        ) == .swallow)
        // 松手先被识别（`onEnded` 已到）：同一个结论 —— 顺序不固定，两种来信都按同一本账量。
        #expect(PlaybackView.tapDisposition(
            isHolding: false,
            pressStartedAt: now.addingTimeInterval(-2.2),
            pressEndedAt: now.addingTimeInterval(-0.2),
            now: now
        ) == .swallow)
        #expect(PlaybackView.tapDisposition(
            isHolding: false,
            pressStartedAt: now.addingTimeInterval(-1.4),
            pressEndedAt: now.addingTimeInterval(-0.2),
            now: now
        ) == .allow)
        // 按得久的（5 秒）也是真·长按：吞 —— 没有「挂太久」的上限（那会把长按的尾巴放进来）。
        #expect(PlaybackView.tapDisposition(
            isHolding: false,
            pressStartedAt: now.addingTimeInterval(-5.2),
            pressEndedAt: now.addingTimeInterval(-0.2),
            now: now
        ) == .swallow)
        // 连按下时刻都没记到：还按着当挂死（自愈 + 放行）；没按着直接放行。
        #expect(PlaybackView.tapDisposition(
            isHolding: true, pressStartedAt: nil, pressEndedAt: nil, now: now
        ) == .endStaleBoost)
        #expect(PlaybackView.tapDisposition(
            isHolding: false, pressStartedAt: nil, pressEndedAt: now, now: now
        ) == .allow)
    }
}
