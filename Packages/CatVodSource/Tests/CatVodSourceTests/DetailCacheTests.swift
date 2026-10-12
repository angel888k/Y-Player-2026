import CatVodCore
import CatVodNet
@testable import CatVodSource
import Foundation
import Testing

/// 记录请求次数的假传输层。
actor DetailCountingTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private let response: HTTPResponse

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }

    func count() -> Int {
        requests.count
    }
}

private let detailJSON = #"""
{"code":0,"list":[{"vod_id":"1","vod_name":"示例","vod_play_from":"线路1",
"vod_play_url":"第1集$http://cdn.example.com/1.m3u8"}]}
"""#

private func cmsSite() -> Site {
    Site(key: "cms", name: "CMS 站点", type: 1, api: "https://api.example.com")
}

private func spiderSite() -> Site {
    Site(key: "cat", name: "猫源", type: 3, api: "http://127.0.0.1:9988/spider/cat")
}

private func makeProvider(
    capacity: Int = 8,
    ttl: TimeInterval = 300
) -> (provider: DetailProvider, transport: DetailCountingTransport) {
    let transport = DetailCountingTransport(response: HTTPResponse(status: 200, body: Data(detailJSON.utf8)))
    let cache = DetailCache(configuration: .init(ttl: ttl, capacity: capacity))
    return (DetailProvider(client: SiteClient(transport: transport), cache: cache), transport)
}

private func decodeResult(_ json: String) throws -> SpiderResult {
    try JSONDecoder().decode(SpiderResult.self, from: Data(json.utf8))
}

@Suite("详情缓存（TTL + 挡板）")
struct DetailCacheTests {
    @Test("可缓存站点：第二次请求命中缓存")
    func cacheHit() async throws {
        let site = cmsSite()
        let (provider, transport) = makeProvider()

        let first = try await provider.detail(site: site, vodID: "1")
        let second = try await provider.detail(site: site, vodID: "1")

        #expect(first.list.count == 1)
        #expect(second.list.count == 1)
        let requestCount = await transport.count()
        #expect(requestCount == 1)

        let stats = await provider.cacheStatistics()
        #expect(stats.hits == 1)
        #expect(stats.stores == 1)
        #expect(stats.count == 1)
    }

    @Test("不同 vodID 互不干扰")
    func cacheKeyIncludesVodID() async throws {
        let site = cmsSite()
        let (provider, transport) = makeProvider()

        _ = try await provider.detail(site: site, vodID: "1")
        _ = try await provider.detail(site: site, vodID: "2")
        _ = try await provider.detail(site: site, vodID: "1")

        let requestCount = await transport.count()
        #expect(requestCount == 2)
        let stats = await provider.cacheStatistics()
        #expect(stats.count == 2)
    }

    @Test("js2p 站点也缓存（M28P10）：第二次进详情不再打宿主")
    func spiderCacheHit() async throws {
        let site = spiderSite()
        #expect(DetailCache.shouldCache(site: site))

        let (provider, transport) = makeProvider()
        let first = try await provider.detail(site: site, vodID: "1")
        #expect(first.list.count == 1)
        // 第一次包含 `POST /init` + `POST /detail` 两次往返（init 每个站点只发一次）。
        let afterFirst = await transport.count()

        _ = try await provider.detail(site: site, vodID: "1")
        let afterSecond = await transport.count()
        #expect(afterSecond == afterFirst, "第二次进详情应当命中缓存，一次宿主都不打")

        let stats = await provider.cacheStatistics()
        #expect(stats.hits == 1)
    }

    @Test("JAR / 设置类 Spider 仍不缓存（挡板 1）")
    func spiderBypass() async throws {
        // js2p（api 含 /spider/）在 M28P10 起**允许**缓存（见上一条）；这里盯的是其余 Spider。
        let jar = Site(key: "jar", name: "JAR 站", type: 3, api: "csp_test")
        #expect(!DetailCache.shouldCache(site: jar))
        #expect(DetailCache.shouldCache(site: cmsSite()))

        let cache = DetailCache()
        let result = try decodeResult(detailJSON)
        let stored = await cache.store(result, site: jar, vodID: "1")
        #expect(!stored)

        let cached = await cache.result(site: jar, vodID: "1")
        #expect(cached == nil)

        let stats = await cache.statistics()
        #expect(stats.bypasses == 2)
        #expect(stats.isEmpty)
    }

    @Test("TTL 过期后视为未命中（挡板 3 的兜底）")
    func ttlExpiry() async throws {
        let site = cmsSite()
        let cache = DetailCache(configuration: .init(ttl: 60, capacity: 4))
        let result = try decodeResult(detailJSON)
        let start = Date()
        _ = await cache.store(result, site: site, vodID: "1", now: start)

        let fresh = await cache.result(site: site, vodID: "1", now: start.addingTimeInterval(30))
        #expect(fresh != nil)

        let expired = await cache.result(site: site, vodID: "1", now: start.addingTimeInterval(61))
        #expect(expired == nil)

        let stats = await cache.statistics()
        #expect(stats.isEmpty)
    }

    @Test("失败或空结果不缓存（挡板 2）")
    func uncacheableResults() async throws {
        let empty = SpiderResult()
        #expect(!DetailCache.isCacheable(empty))

        let errorResult = try decodeResult(#"{"code":1,"msg":"站点维护中","list":[{"vod_id":"1"}]}"#)
        #expect(!DetailCache.isCacheable(errorResult))

        let cache = DetailCache()
        let stored = await cache.store(errorResult, site: cmsSite(), vodID: "1")
        #expect(!stored)
    }

    @Test("容量上限按写入顺序淘汰最旧条目")
    func capacityEviction() async throws {
        let site = cmsSite()
        let cache = DetailCache(configuration: .init(ttl: 300, capacity: 2))
        let result = try decodeResult(detailJSON)

        _ = await cache.store(result, site: site, vodID: "1")
        _ = await cache.store(result, site: site, vodID: "2")
        _ = await cache.store(result, site: site, vodID: "3")

        let evicted = await cache.result(site: site, vodID: "1")
        #expect(evicted == nil)
        let kept = await cache.result(site: site, vodID: "3")
        #expect(kept != nil)

        let stats = await cache.statistics()
        #expect(stats.count == 2)
    }

    @Test("invalidate 与 forceRefresh 必须能绕过缓存")
    func invalidation() async throws {
        let site = cmsSite()
        let (provider, transport) = makeProvider()

        _ = try await provider.detail(site: site, vodID: "1")
        await provider.invalidate(site: site, vodID: "1")
        _ = try await provider.detail(site: site, vodID: "1")
        _ = try await provider.detail(site: site, vodID: "1", forceRefresh: true)

        let requestCount = await transport.count()
        #expect(requestCount == 3)

        await provider.invalidateAll()
        let stats = await provider.cacheStatistics()
        #expect(stats.isEmpty)
    }
}
