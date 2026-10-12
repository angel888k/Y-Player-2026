import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

@Suite("聚合搜索：搜哪些站点 / 结果怎么归位")
struct AggregateSearchTests {
    /// 造一个能搜的站点（`type=1` 走 CMS 通道，`availability` 自然是可用）。
    private func site(
        key: String,
        name: String = "",
        indexs: Int = 0,
        searchable: Int = 1,
        timeout: Int = 15
    ) -> Site {
        Site(
            key: key,
            name: name,
            type: 1,
            api: "https://example.com/\(key)",
            indexs: indexs,
            timeout: timeout,
            searchable: searchable
        )
    }

    @Test("可搜站点：永久禁搜与平台不可用的都不算，临时禁搜（2）仍算")
    func searchableSitesFilters() {
        let sites = [site(key: "a"), site(key: "b", searchable: 0), site(key: "c", searchable: 2)]
        #expect(AggregateSearchRules.searchableSites(sites: sites).map(\.key) == ["a", "c"])
    }

    @Test("筛选站源：用户关掉的站点不参与，哪怕它本来能搜")
    func enabledExcludesSwitchedOffSites() {
        let sites = [site(key: "a"), site(key: "b"), site(key: "c", searchable: 0)]
        #expect(AggregateSearchRules.enabled(sites: sites, excluding: ["b"]).map(\.key) == ["a"])
    }

    @Test("面板置灰的原因：能搜=没有原因；关搜索 / 平台跑不了各有各的说法")
    func searchDisabledReasons() {
        #expect(AggregateSearchRules.searchDisabledReason(site(key: "a")) == nil)
        #expect(AggregateSearchRules.searchDisabledReason(site(key: "b", searchable: 0)) == "配置里关了搜索（searchable = 0）")
        // csp_ 开头的 JAR 站点在 Apple 平台跑不了（原因里带 JVM）。
        let jarSite = Site(key: "c", name: "JAR 站", type: 3, api: "csp_test")
        #expect(AggregateSearchRules.searchDisabledReason(jarSite)?.contains("JVM") == true)
    }

    @Test("索引站点排最前，但不是「只搜它们」——其余站点照样跟在后面（M28P15 口径）")
    func prefersIndexSites() {
        let sites = [site(key: "a"), site(key: "b", indexs: 1), site(key: "c", indexs: 1)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["b", "c", "a"])
    }

    @Test("一个索引站点都没有就回落全部可搜站点（新配置常常没人标 indexs）")
    func fallsBackToAllSearchable() {
        let sites = [site(key: "a"), site(key: "b")]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["a", "b"])
    }

    @Test("先搜哪些：索引站点排最前，其余跟在后面；**不截断**（搜索要覆盖所有站点）")
    func targetsOrderIsNotATruncation() {
        // 30 个站点一个都没标索引：照站点清单顺序，一个都不少。
        let plain = (1 ... 30).map { site(key: "s\($0)") }
        #expect(AggregateSearchRules.targets(sites: plain).map(\.key) == (1 ... 30).map { "s\($0)" })

        // 标了索引站点：它们排最前，其余照原顺序跟上（全都在，只是顺序不同）。
        var mixed = (1 ... 6).map { site(key: "s\($0)") }
        mixed[3] = site(key: "s4", indexs: 1)
        mixed[5] = site(key: "s6", indexs: 1)
        #expect(AggregateSearchRules.targets(sites: mixed).map(\.key) == ["s4", "s6", "s1", "s2", "s3", "s5"])
    }

    @Test("总时长预算：没到点就接着开新站点，到点就只等手里的（一轮搜索总要收尾）")
    func searchTimeBudget() {
        let now = Date()
        let deadline = now.addingTimeInterval(AggregateSearchRules.searchTimeLimit)
        #expect(AggregateSearchRules.shouldStartAnotherSite(now: now, deadline: deadline))
        #expect(!AggregateSearchRules.shouldStartAnotherSite(now: deadline, deadline: deadline))
        #expect(!AggregateSearchRules.shouldStartAnotherSite(now: deadline.addingTimeInterval(5), deadline: deadline))
    }

    @Test("聚合搜索的单站超时：上限 8 秒；站点配得更短就听站点的，配 0 也按 1 秒兜底")
    func searchTimeoutIsCapped() {
        #expect(AggregateSearchRules.searchTimeout(for: site(key: "a")) == 8)
        #expect(AggregateSearchRules.searchTimeout(for: site(key: "b", timeout: 5)) == 5)
        #expect(AggregateSearchRules.searchTimeout(for: site(key: "c", timeout: 0)) == 1)
    }

    @Test("永久禁搜（searchable=0）的站点不进候选，哪怕标了 indexs")
    func skipsSearchDisabledSites() {
        let sites = [site(key: "a", indexs: 1, searchable: 0), site(key: "b", indexs: 1)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["b"])
    }

    @Test("临时禁搜（searchable=2）仍进候选：口径与换源一致（isUsable）")
    func keepsTemporarilyDisabledSites() {
        let sites = [site(key: "a", searchable: 2)]
        #expect(AggregateSearchRules.targets(sites: sites).map(\.key) == ["a"])
    }

    @Test("归位：只留有命中的站点、顺序照站点清单（并发谁先回来不算数）")
    func sectionsKeepSiteOrder() {
        let sites = [site(key: "a"), site(key: "b"), site(key: "c")]
        let hits = [
            "c": [VodItem(vodID: "3", vodName: "丙")],
            "a": [VodItem(vodID: "1", vodName: "甲")],
        ]
        let sections = AggregateSearchRules.sections(
            sites: sites,
            hits: hits,
            names: ["a": "甲站", "c": "丙站"]
        )
        #expect(sections.map(\.site.key) == ["a", "c"])
        #expect(sections.map(\.siteName) == ["甲站", "丙站"])
        #expect(sections.map(\.count) == [1, 1])
    }

    @Test("零命中与搜索失败一样：都不占左栏的位置")
    func emptyHitsAreDropped() {
        let sites = [site(key: "a"), site(key: "b"), site(key: "c")]
        // b 搜到了但是空的、c 整个没进 hits（= 请求失败被跳过）。
        let hits = ["a": [VodItem(vodID: "1")], "b": []]
        #expect(AggregateSearchRules.sections(sites: sites, hits: hits).map(\.site.key) == ["a"])
    }

    @Test("展示名缺失时回落站点原名；名字也空就回落 key")
    func nameFallsBack() {
        let sites = [site(key: "a", name: "甲站"), site(key: "b")]
        let hits = ["a": [VodItem(vodID: "1")], "b": [VodItem(vodID: "2")]]
        let sections = AggregateSearchRules.sections(sites: sites, hits: hits)
        #expect(sections.map(\.siteName) == ["甲站", "b"])
    }
}
