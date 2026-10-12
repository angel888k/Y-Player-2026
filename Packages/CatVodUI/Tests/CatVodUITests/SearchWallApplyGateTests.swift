@testable import CatVodUI
import Foundation
import Testing

@Suite("搜索墙：刷墙节流闸")
struct SearchWallApplyGateTests {
    @Test("首份立即上墙；间隔内的回报跳过；到点再上（收尾那份由调用方无条件补刷）")
    func coalescesBursts() {
        var gate = SearchWallApplyGate()
        let startedAt = Date()
        #expect(gate.shouldApply(now: startedAt))
        #expect(!gate.shouldApply(now: startedAt.addingTimeInterval(0.01)))
        #expect(!gate.shouldApply(now: startedAt.addingTimeInterval(0.08)))
        #expect(gate.shouldApply(now: startedAt.addingTimeInterval(0.09)))
        #expect(gate.shouldApply(now: startedAt.addingTimeInterval(10)))
    }
}
