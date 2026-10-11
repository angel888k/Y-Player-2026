import Combine
import Foundation
@testable import CatVodUI
import Testing

/// 发现页底部 Tab 栏的「门」（M28 首验之二十九）：**只在 `isHidden` 真的翻转时**才广播 ——
/// 这是那场滚动卡顿定案后的行为契约（每帧摸门不再牵动 `HomeView`，广播次数也必须少）。
@Suite("发现页 Tab 栏收放的门")
@MainActor
struct DiscoverTabBarGateTests {
    @Test("同一次拖动里反复报同一个位移：只在第一次收起时广播一次")
    func publishesOnlyOnFlip() {
        let gate = DiscoverTabBarGate()
        var changes: [Bool] = []
        let cancellable = gate.$isHidden.dropFirst().sink { changes.append($0) }
        defer { cancellable.cancel() }

        gate.touchDown()
        gate.dragChanged(translationX: 0, translationY: -20)
        gate.dragChanged(translationX: 0, translationY: -20)
        gate.dragChanged(translationX: 0, translationY: -20)
        gate.touchEnded()

        #expect(changes == [true], "只该广播一次（收起的翻转）——多出来的每一次都是一轮整页重建")

        gate.touchDown()
        #expect(changes == [true, false], "再次触碰展开：第二次广播")
    }

    @Test("往下滑 / 横向滑不收：不广播")
    func noPublishForDownwardOrHorizontal() {
        let gate = DiscoverTabBarGate()
        var changes: [Bool] = []
        let cancellable = gate.$isHidden.dropFirst().sink { changes.append($0) }
        defer { cancellable.cancel() }

        gate.touchDown()
        gate.dragChanged(translationX: 0, translationY: 40)
        gate.dragChanged(translationX: 80, translationY: -6)
        gate.touchEnded()

        #expect(changes.isEmpty, "本来就收着/没收起，一次广播都不该有")
    }

    @Test("离页强制展开：由收起翻回展开才广播")
    func revealPublishesWhenHidden() {
        let gate = DiscoverTabBarGate()
        var changes: [Bool] = []
        let cancellable = gate.$isHidden.dropFirst().sink { changes.append($0) }
        defer { cancellable.cancel() }

        gate.touchDown()
        gate.dragChanged(translationX: 0, translationY: -20)
        gate.reveal()

        #expect(changes == [true, false])
    }
}
