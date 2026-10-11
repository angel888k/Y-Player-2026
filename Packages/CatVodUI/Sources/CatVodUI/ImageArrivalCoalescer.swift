import Foundation

/// 图片到达的**合流器**（M28 首验之二十九）：一串图在几毫秒内先后下完时，别让每张都单独触发一次
/// SwiftUI 刷新 —— 攒一小会儿（默认 90ms）一次刷完。
///
/// 为什么需要它：滚动时一屏十来个图会在同一次网络往返里一起回来，每个到达都让一张卡片改 `@State`
/// → 每个都触发一轮渲染。上机帧账（`滚动帧`）显示主线程会整段被占 55~110ms，中位却不差（16ms）——
/// 就是这种「一簇一簇」的刷新把帧顶掉了。攒批之后：一簇只刷一次。
///
/// 交互约定：视图只「表个意向」（``notifyWaiting(url:)``），实际取值仍从 ``ImageLoader`` 的
/// 内存缓存读 —— 合流器不接管数据，只负责「什么时候一起刷」。
/// 线程约定：**只在主线程用**（视图加载、订阅、刷新都在主线程）。类本身不标 `@MainActor` 是
/// 有意的 —— `ImageLoader.init` 是非隔离的（`AppModel.init` 里建），带隔离标注的成员就建不了。
final class ImageArrivalCoalescer {
    private let flushDelayNanoseconds: UInt64
    /// 正在等图的 URL（去重；视图多次表意向也只算一份）。
    private var pending: Set<String> = []
    /// 上一次真刷新的时刻（离得够久就立刻刷，别让单张图也等 90ms）。
    private var lastFlush = Date.distantPast
    private var flushScheduled = false
    /// 每个在等的视图一条**自己的**流：`AsyncStream` 是单消费者语义，共用一条会互相抢
    /// （一张卡拿到刷新、其余全挂住）。
    private var subscribers: [(id: UUID, continuation: AsyncStream<Void>.Continuation)] = []

    /// 一次刷新的间隔（默认 90ms）：比一帧长、比人眼能察觉的「图该出来了」短。
    static let defaultFlushDelay: UInt64 = 90_000_000
    /// 距上次刷新超过这个间隔就立刻刷（单张图的场景不攒）。
    static let immediateFlushInterval: TimeInterval = 0.1

    init(flushDelayNanoseconds: UInt64 = defaultFlushDelay) {
        self.flushDelayNanoseconds = flushDelayNanoseconds
    }

    /// 订阅刷新信号（`CachedImage` 用；视图消失时订阅自动注销）。
    func subscribe() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers.append((id: id, continuation: continuation))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeSubscriber(id)
            }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeAll { $0.id == id }
    }

    /// 视图表意向：我在等这个 URL。
    func notifyWaiting(url: String) {
        guard !url.isEmpty else {
            return
        }
        pending.insert(url)
        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !flushScheduled else {
            return
        }
        let elapsed = Date().timeIntervalSince(lastFlush)
        if elapsed >= Self.immediateFlushInterval {
            flush()
            return
        }
        flushScheduled = true
        let delay = flushDelayNanoseconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.flushIfScheduled()
        }
    }

    private func flushIfScheduled() {
        guard flushScheduled else {
            return
        }
        flush()
    }

    private func flush() {
        flushScheduled = false
        lastFlush = Date()
        pending.removeAll(keepingCapacity: true)
        for subscriber in subscribers {
            subscriber.continuation.yield()
        }
    }
}
