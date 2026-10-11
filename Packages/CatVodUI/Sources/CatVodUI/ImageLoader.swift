import CoreGraphics
import Foundation

/// 图片加载器：**内存缓存 + HTTP 磁盘缓存 + 同 URL 去重 + 尺寸下采样**。
///
/// 为什么需要它（M28 首验之二十九）：全 App 的图原来都用 `AsyncImage` —— 它没有内存缓存，
/// 列表滚动时卡片被回收再回来就会**重新下载 + 重新解码**；解码还发生在主线程、按原始尺寸解，
/// 几个大图就能把滑动拖成幻灯片。发现页、列表、直播、详情都吃这个亏。
///
/// 职责划分：
/// - ``ImageMemoryCache``（actor）：解码后的图片（`PlatformImage`，已按目标尺寸下采样）+ 在途请求去重。
///   同一张图被几处同时要（分区横滑 + 纵向网格会重叠）时**只发一次网络请求**，其余等结果；
/// - ``ImageDiskCache``：`URLCache` 做 HTTP 层缓存，图缓存在 Caches 目录、按服务器的
///   `Cache-Control` 决定新鲜度；超容量由 `URLCache` 自己清理 —— 与「设置 → 缓存管理」
///   的清缓存口径一致（清的是缓存目录，不碰用户数据）；
/// - 下采样在**后台线程**做（`ImageIO` 的缩略图解码），主线程只拿成品 —— 这一点是
///   `AsyncImage` 换掉之后最直接的收益。
public final class ImageLoader: @unchecked Sendable {
    /// 共享实例：没注入环境时的兜底（预览 / 单测）。生产由 `RootView` 注入 `AppModel` 那份。
    public static let shared = ImageLoader()

    let session: URLSession
    let memory: ImageMemoryCache
    /// HTTP 磁盘缓存（「缓存管理 → 图片缓存」的清理要同时清它 —— 只删目录的话，
    /// 进程内这份还会把已删的响应继续喂回来）。
    let diskCache: URLCache

    /// - Parameters:
    ///   - memoryCapacity: 内存缓存上限（字节，默认 128 MB —— 几十 KB 一张的缩略图能装几千张）；
    ///   - diskCapacity: 磁盘缓存上限（字节，默认 256 MB）；
    ///   - cacheDirectory: 磁盘缓存目录（`YPlayer/Caches/Images`）；nil = 系统 Caches 下的兜底目录；
    ///   - protocolClasses: 单测注入 `URLProtocol` 桩用（生产保持 nil）。
    public init(
        memoryCapacity: Int = 128 * 1024 * 1024,
        diskCapacity: Int = 256 * 1024 * 1024,
        cacheDirectory: URL? = nil,
        protocolClasses: [AnyClass]? = nil
    ) {
        let diskURL = cacheDirectory ?? Self.fallbackDiskDirectory()
        try? FileManager.default.createDirectory(at: diskURL, withIntermediateDirectories: true)
        let urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: diskCapacity,
            directory: diskURL
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        // 每个 host 的并发连接别开太大：图床很多是小站，猛并发反而慢且更容易被限。
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        diskCache = urlCache
        memory = ImageMemoryCache(capacity: memoryCapacity)
    }

    /// 清空缓存（磁盘 + 内存）：与「缓存管理」里清目录同一件事，内存那份不清会立刻「复活」刚删的图。
    func clear() async {
        diskCache.removeAllCachedResponses()
        await memory.removeAll()
    }

    /// 没注入目录时的兜底：系统 Caches 下（单测 / 预览用，不碰真沙盒布局）。
    static func fallbackDiskDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImageCache", isDirectory: true)
    }

    /// 取图：命中内存缓存直接回；否则下采样解码、顺路写缓存。同一个 URL 的在途请求会合并。
    ///
    /// - Parameters:
    ///   - url: 图片地址；空串 / 非法地址给 ``ImageLoadError/invalidURL``；
    ///   - targetSize: 目标显示尺寸（**像素**：点 × 屏 scale）—— 解码就按它缩，
    ///     别再让主线程碰原始尺寸的大图。比例会保持（ImageIO 的 thumbnail 语义）。
    /// 只给模块内的 ``CachedImage`` 用：返回的是 `PlatformImage`（internal 的平台别名），
    /// 不对外暴露 —— 公开一个 internal 类型会让外部调用方拿到编不过的类型。
    func image(for url: String, targetSize: CGSize) async throws -> PlatformImage {
        guard let requestURL = URL(string: url) else {
            throw ImageLoadError.invalidURL
        }
        return try await memory.image(for: url, targetSize: targetSize) { [session] _, size in
            let (data, response) = try await session.data(from: requestURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImageLoadError.badStatus(http.statusCode)
            }
            guard let image = platformDownsample(data, to: size) else {
                throw ImageLoadError.decodeFailed
            }
            return image
        }
    }
}

/// 图片加载的错误（都不给用户弹窗：图挂了显示占位即可）。
public enum ImageLoadError: Error, Equatable {
    /// 地址为空或非法。
    case invalidURL
    /// HTTP 状态码不是 2xx。
    case badStatus(Int)
    /// 数据解不出图片。
    case decodeFailed
    /// 请求本身失败（断网 / 超时等）。
    case transport(String)
}

/// 内存缓存 + 同 URL 在途请求去重（actor：所有读写都在这里排队）。
///
/// 缓存键 = 「URL + 目标尺寸」：同一张图在网格（112pt 宽）与详情页（半屏宽）各自按自己的
/// 尺寸解码，互不顶掉；而**在途合并**只按 URL —— 同一张图同时被几处要时只发一次请求。
actor ImageMemoryCache {
    private let cache = NSCache<NSString, PlatformImage>()
    /// 在途请求的登记簿：同一个 URL 只跑一个 `Task`，后来的等它；等的人全走了就取消（见 ``sharedTask``）。
    private var result: [String: InFlight] = [:]
    /// 缓存命中 / 未命中计数（单测用：证「第二次不再走网络」）。
    private(set) var hits = 0
    private(set) var misses = 0

    /// 在途请求登记：`Task` 包一层才进字典（`Task` 是 struct，不能拿 `ObjectIdentifier` 认它，
    /// 用自增的 `token` 认领）。
    ///
    /// 类而不是结构体：`Task` 自己的闭包里要引用「这份登记」（撤销时认领 `token`），
    /// 结构体进闭包会拷一份 —— 改的就成了副本，认领永远对不上。
    private final class InFlight {
        let task: Task<PlatformImage, Error>
        /// 这份登记的唯一号（``forget(url:token:)`` 认它，防止把新顶上的任务误删）。
        let token: Int
        /// 还在等这个 URL 的人（含发起者）。归零 = 没人要了，取消。
        var waiters: Int

        init(task: Task<PlatformImage, Error>, token: Int, waiters: Int) {
            self.task = task
            self.token = token
            self.waiters = waiters
        }
    }

    /// 登记号的下一个值（只增不减，够用）。
    private var nextToken = 0

    init(capacity: Int) {
        cache.totalCostLimit = capacity
    }

    var hitCount: Int { hits }
    var missCount: Int { misses }

    /// 清空内存缓存与在途登记（清缓存入口用）：在途的也取消，等的人会拿到失败占位。
    func removeAll() {
        cache.removeAllObjects()
        for entry in result.values {
            entry.task.cancel()
        }
        result = [:]
    }

    func image(
        for url: String,
        targetSize: CGSize,
        fetch: @Sendable (String, CGSize) async throws -> PlatformImage
    ) async throws -> PlatformImage {
        let size = Self.pixelSize(targetSize)
        let key = Self.cacheKey(url, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            hits += 1
            return cached
        }
        misses += 1
        let task = sharedTask(url: url, key: key, size: size, fetch: fetch)
        do {
            let image = try await task.value
            await leave(url: url)
            return image
        } catch {
            await leave(url: url)
            throw error
        }
    }

    /// 像素化目标尺寸（点 × scale）：两层都按 1pt = 1px 走，scale 由调用方乘好。
    private nonisolated static func pixelSize(_ size: CGSize) -> CGSize {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        return CGSize(width: width, height: height)
    }

    /// 缓存键（`URL#宽x高`）：视图侧要先用它查内存缓存（命中就同步出图，不闪占位）。
    nonisolated static func cacheKey(_ url: String, size: CGSize) -> String {
        let size = pixelSize(size)
        return "\(url)#\(Int(size.width))x\(Int(size.height))"
    }

    /// 同步查内存缓存（不走 actor）：命中就当场给图 —— `CachedImage` 的快速路径。
    nonisolated func cachedImage(for url: String, targetSize: CGSize) -> PlatformImage? {
        cache.object(forKey: Self.cacheKey(url, size: targetSize) as NSString)
    }

    /// 拿这个 URL 的在途 `Task`（有就 +1 等位；没有就现起一个）。
    ///
    /// 取消口径：等的人全部离场（滚动回收 / 视图消失）就把在途任务取消 —— 下载不白跑；
    /// 只要还有人在等，发起者的取消**不牵连**其他人（等的是同一个 `Task`，不是发起者的）。
    private func sharedTask(
        url: String,
        key: String,
        size: CGSize,
        fetch: @escaping @Sendable (String, CGSize) async throws -> PlatformImage
    ) -> Task<PlatformImage, Error> {
        if let entry = result[url] {
            entry.waiters += 1
            return entry.task
        }
        // 先取号：`Task` 的闭包里要拿它认领自己那一份（token 定死再进闭包，登记随建随存）。
        nextToken += 1
        let token = nextToken
        let cache = self
        // `Task.detached`：**在途任务不继承发起者的取消** —— 发起者可能只是滚动回收的一个卡片，
        // 还有别人在等这份结果（谁都不等时由 ``leave(url:)`` 明确取消，不动别人）。
        let task = Task<PlatformImage, Error>.detached {
            do {
                let image = try await fetch(url, size)
                await cache.store(image, key: key, url: url)
                return image
            } catch {
                // 撤销登记要**认准自己那一份**：这中间可能已经有新的同名任务顶上（见 ``forget(url:token:)``）。
                await cache.forget(url: url, token: token)
                throw error
            }
        }
        result[url] = InFlight(task: task, token: token, waiters: 1)
        return task
    }

    /// 一个等位离场（`.value` 返回或抛错之后都算）。
    func leave(url: String) {
        guard let entry = result[url] else {
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            result[url] = nil
        }
    }

    /// 下载成功：写内存缓存并撤销登记。
    private func store(_ image: PlatformImage, key: String, url: String) {
        // cost 按像素算：NSCache 的超限回收就会优先扔大图。
        let cost = Int(image.platformSize.width * image.platformSize.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        result[url] = nil
    }

    /// 下载失败：撤销登记 —— 只有当前登记的**还是我这份（token 对得上）**时才撤
    /// （失败前可能已被 `leave` 摘掉、或有新任务顶上，别把别人的登记误删）。
    private func forget(url: String, token: Int) {
        guard let entry = result[url], entry.token == token else {
            return
        }
        result[url] = nil
    }
}
