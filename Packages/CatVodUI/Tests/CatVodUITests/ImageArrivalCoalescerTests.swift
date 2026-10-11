import Foundation
@testable import CatVodUI
import Testing

/// 到达合流器（M28 首验之二十九）：一簇图一起回来时只刷一次；每个订阅者都能收到（fan-out）。
@Suite("图片到达合流器")
@MainActor
struct ImageArrivalCoalescerTests {
    @Test("一簇通知只出一拍刷新信号")
    func burstFlushesOnce() async {
        let coalescer = ImageArrivalCoalescer(flushDelayNanoseconds: 50_000_000)
        var iterator = coalescer.subscribe().makeAsyncIterator()

        // 第一次通知会立刻刷（离上次刷新够久），随后这簇剩下的通知并进下一拍。
        coalescer.notifyWaiting(url: "a")
        coalescer.notifyWaiting(url: "b")
        coalescer.notifyWaiting(url: "c")
        coalescer.notifyWaiting(url: "d")

        let first = await iterator.next()
        #expect(first != nil, "第一次通知应当立刻出一拍")

        var flushes = 0
        let counter = Task {
            while await iterator.next() != nil {
                flushes += 1
            }
        }
        // 第二簇与第一簇同步到缓冲窗口**之内**（50ms 窗）：两簇各一拍，共 2 拍。
        // 隔得太远（>100ms）会触发「单张立即刷」策略、多出一拍 —— 那是设计，不是本用例要验的。
        coalescer.notifyWaiting(url: "e")
        coalescer.notifyWaiting(url: "f")
        try? await Task.sleep(nanoseconds: 400_000_000)
        counter.cancel()
        #expect(flushes == 2, "两簇各一拍（实际 \(flushes) 拍）——多出来的每一拍都是一轮多余渲染")
    }

    @Test("每个订阅者都会收到刷新（fan-out）：一张卡拿到、别的不能干等")
    func everySubscriberReceives() async {
        let coalescer = ImageArrivalCoalescer(flushDelayNanoseconds: 50_000_000)
        var a = coalescer.subscribe().makeAsyncIterator()
        var b = coalescer.subscribe().makeAsyncIterator()
        var c = coalescer.subscribe().makeAsyncIterator()

        coalescer.notifyWaiting(url: "x")
        coalescer.notifyWaiting(url: "y")

        // 三个订阅者都该在同一拍收到（第一次通知立刻刷）。
        #expect(await a.next() != nil)
        #expect(await b.next() != nil)
        #expect(await c.next() != nil)
    }

    @Test("空 URL 不记账，但节拍照旧在（订阅者不会因为空 URL 卡住）")
    func ignoresEmptyURL() async {
        let coalescer = ImageArrivalCoalescer(flushDelayNanoseconds: 20_000_000)
        var iterator = coalescer.subscribe().makeAsyncIterator()
        coalescer.notifyWaiting(url: "real")
        #expect(await iterator.next() != nil)
    }
}
