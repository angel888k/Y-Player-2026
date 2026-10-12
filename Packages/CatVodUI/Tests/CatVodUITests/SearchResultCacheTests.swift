@testable import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// 聚合搜索的结果缓存（M28P5）：只存命中、有有效期、有上限 —— 让「同一部片重搜」不用再从零等。
@Suite("聚合搜索：结果缓存（站点 + 关键词）")
struct SearchResultCacheTests {
    /// 固定时间锚点：有效期 / 淘汰都按注入的 `now` 算，测试不依赖真实时钟。
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String) -> VodItem {
        VodItem(vodID: name, vodName: name)
    }

    @Test("存过就读得到；没存过的站点没有；空结果不占缓存")
    func storeAndHit() async {
        let cache = SearchResultCache()
        await cache.store([item("一"), item("二")], forSiteKey: "a", keyword: "狂王", now: base)

        let hits = await cache.hits(forSiteKeys: ["a", "b"], keyword: "狂王", now: base)
        #expect(hits["a"]?.count == 2)
        #expect(hits["b"] == nil)
        #expect(await cache.count() == 1)

        await cache.store([], forSiteKey: "c", keyword: "狂王", now: base)
        #expect(await cache.count() == 1, "空结果不是「这个站点没有」，别占缓存")
    }

    @Test("过了有效期不命中（有效期内才算数）")
    func expires() async {
        let cache = SearchResultCache()
        await cache.store([item("一")], forSiteKey: "a", keyword: "狂王", now: base)

        let fresh = await cache.hits(
            forSiteKeys: ["a"],
            keyword: "狂王",
            now: base.addingTimeInterval(SearchResultCache.lifetime - 1)
        )
        #expect(fresh["a"] != nil)

        let stale = await cache.hits(
            forSiteKeys: ["a"],
            keyword: "狂王",
            now: base.addingTimeInterval(SearchResultCache.lifetime + 1)
        )
        #expect(stale["a"] == nil, "过期就该当没有，去走实时搜索")
    }

    @Test("关键词归一化：大小写与首尾空白算同一个词")
    func normalizesKeyword() async {
        let cache = SearchResultCache()
        await cache.store([item("Funny")], forSiteKey: "a", keyword: "  Funny  ", now: base)

        #expect(await cache.hits(forSiteKeys: ["a"], keyword: "funny", now: base)["a"]?.count == 1)
        #expect(await cache.hits(forSiteKeys: ["a"], keyword: " FUNNY ", now: base)["a"]?.count == 1)
        #expect(SearchResultCache.normalize("\tFunny\n") == "funny")
    }

    @Test("超上限先丢最久没写过的")
    func prunesOldest() async {
        let cache = SearchResultCache()
        let total = SearchResultCache.limit + 5
        for index in 0 ..< total {
            await cache.store(
                [item("v\(index)")],
                forSiteKey: "s\(index)",
                keyword: "k",
                now: base.addingTimeInterval(Double(index))
            )
        }
        #expect(await cache.count() == SearchResultCache.limit)

        let hits = await cache.hits(
            forSiteKeys: ["s0"],
            keyword: "k",
            now: base.addingTimeInterval(Double(total))
        )
        #expect(hits.isEmpty, "最早写的那条应当已被淘汰")
    }

    @Test("清空（换接口 / 宿主站点刷新时用）")
    func removeAll() async {
        let cache = SearchResultCache()
        await cache.store([item("一")], forSiteKey: "a", keyword: "k", now: base)
        await cache.removeAll()
        #expect(await cache.count() == 0)
    }
}
