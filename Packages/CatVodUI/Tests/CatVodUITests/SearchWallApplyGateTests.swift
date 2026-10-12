@testable import CatVodUI
import Foundation
import Testing

@Suite("搜索墙：刷墙节流闸")
struct SearchWallApplyGateTests {
    @Test("首份立即上墙；间隔内的回报跳过；到点再上（收尾那份由调用方无条件补刷）")
    func coalescesBursts() {
        // `#expect` 的宏展开会把表达式装进闭包（捕获值不可变）：mutating 的结果先取出来再断言。
        var gate = SearchWallApplyGate()
        let startedAt = Date()
        let first = gate.shouldApply(now: startedAt)
        let tooSoon = gate.shouldApply(now: startedAt.addingTimeInterval(0.01))
        let stillTooSoon = gate.shouldApply(now: startedAt.addingTimeInterval(0.08))
        let atInterval = gate.shouldApply(now: startedAt.addingTimeInterval(0.09))
        let muchLater = gate.shouldApply(now: startedAt.addingTimeInterval(10))
        #expect(first)
        #expect(!tooSoon)
        #expect(!stillTooSoon)
        #expect(atInterval)
        #expect(muchLater)
    }
}
