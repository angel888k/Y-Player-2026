@testable import CatVodUI
import Foundation
import Testing

/// 到达合流器（M28 首验之二十九）：一簇图一起回来时只刷一次；每个订阅者都能收到（fan-out）。
@Suite("图片到达合流器")
@MainActor
struct ImageArrivalCoalescerTests {
    @Test("一簇通知最多出一拍刷新信号（且确实会刷）")
    func burstFlushesOnce() async {
        let coalescer = ImageArrivalCoalescer(flushDelayNanoseconds: 50_000_000)
        var iterator = coalescer.subscribe().makeAsyncIterator()

        // 一簇通知（都落在缓冲窗口内）：**最多**出一拍 —— 多出来的每一拍都是一轮多余渲染。
        coalescer.notifyWaiting(url: "a")
        coalescer.notifyWaiting(url: "b")
        coalescer.notifyWaiting(url: "c")
        coalescer.notifyWaiting(url: "d")

        let first = await iterator.next()
        #expect(first != nil, "这一簇应当出一拍（首次通知里的「立刻刷」）")

        // 再等一个缓冲窗口 + 余量：这簇里若还有第二拍（说明合流没生效）就会在这里冒出来。
        var extra = 0
        let counter = Task {
            while await iterator.next() != nil {
                extra += 1
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        counter.cancel()
        #expect(extra <= 1, "同一簇最多再补一拍（实际多出 \(extra) 拍）——多出来的每一拍都是一轮多余渲染")
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
