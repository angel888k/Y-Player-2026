@testable import CatVodCore
@testable import CatVodNet
@testable import CatVodUI
import Foundation
import Testing

/// AppModel 集成（内联配置 + 临时存档）—— 专门覆盖那些**之前只能靠调用点审查**的接线。
///
/// 这一套的价值不在「再测一遍纯逻辑」（那些各自有单测），而在验「接起来了没有」：
/// 改名有没有真的换掉分组标签、配置里的 `hlsRules` 有没有进 `/m3u8` 的规则盒、统计归零有没有落到提示上。
@Suite("AppModel 集成（内联配置）")
@MainActor
struct AppModelIntegrationTests {
    @Test("内联配置能载入：站点与分组条都出来了")
    func loadsInlineConfig() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load()

        #expect(fixture.model.sites.count == 2)
        #expect(fixture.model.siteGroups == ["主力", "4K", "首页"])
    }

    @Test("改名（M06f）：显示名换掉、旧标签跟着消失、恢复原名能回去")
    func renameSite() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let site = try #require(fixture.model.sites.first { $0.key == "a" })

        fixture.model.renameSite(site, to: "我的甲站")
        #expect(fixture.model.siteDisplayName(for: site) == "我的甲站")
        #expect(fixture.model.siteGroups == ["首页"])

        fixture.model.renameSite(site, to: "")
        #expect(fixture.model.siteDisplayName(for: site) == "[主力]甲站|4K")
        #expect(fixture.model.siteGroups == ["主力", "4K", "首页"])
    }

    @Test("分组顺序（M06e）：上移一格会落到存档里，重排后站点集合不变")
    func moveSiteGroupPersists() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.model.moveSiteGroup("首页", direction: -1)

        // 上移一位：`[主力, 4K, 首页]` → `[主力, 首页, 4K]`
        #expect(fixture.model.siteGroupOrder == ["主力", "首页", "4K"])
        #expect(fixture.model.siteGroups == ["主力", "首页", "4K"])
    }

    @Test("跳过广告（M06k/M06l）：统计落到提示上，归零时提示也清")
    func adSkipNoticeFollowsStats() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        fixture.model.applyAdSkip(AdSkipRecorder.Stats(cleanedPlaylists: 2, removedSegments: 3, removedDurationSec: 12))
        #expect(fixture.model.adSkipNotice == "已跳过广告 3 段，约 12 秒")

        fixture.model.resetAdSkip()
        #expect(fixture.model.adSkipNotice.isEmpty)
        #expect(fixture.model.adSkipRecorder.stats == AdSkipRecorder.Stats())
    }

    @Test("配置项覆盖（M06m）：`hosts` / `doh` 解析得进模型，但本平台不生效 —— 必须出现在告警里")
    func ignoredConfigFieldsAreReported() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.load("""
        {"sites":[{"key":"a","name":"甲站","type":3,"api":"/spider/a"}],
         "hosts":["a.example.com=1.2.3.4"],
         "doh":[{"name":"dns","url":"https://dns.example/dns-query"}]}
        """)

        let coverage = fixture.model.warnings.filter { $0.contains("在本平台不生效") }
        #expect(coverage.count == 2)
        #expect(coverage.contains { $0.contains("`hosts`") })
        #expect(coverage.contains { $0.contains("`doh`") })
    }

    @Test("弹幕开关（M08d 遗留 2）：关掉就**立刻清屏**，不是等下次换集")
    func disablingDanmakuClearsScreen() throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        let playing = try #require(DanmakuLine(params: "3.0,1,25,16711680", text: "还在播的弹幕"))
        fixture.model.danmakuLines = [playing]
        fixture.model.danmakuStatus = .loaded(source: "示例源", count: 1)

        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: false, addresses: ["https://d.example.com"])

        #expect(fixture.model.danmakuLines.isEmpty)
        #expect(fixture.model.danmakuStatus == .idle)

        // 只是改地址槽、开关还开着 → 不该顺手清掉正在播的弹幕
        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["https://d.example.com"])
        fixture.model.danmakuLines = [playing]
        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["", "", "", ""])
        #expect(fixture.model.danmakuLines.count == 1)
    }

    @Test("落盘往返（M08f）：写进去的偏好在**新建的**模型里读得回来")
    func preferencesRoundTrip() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let site = try #require(fixture.model.sites.first { $0.key == "a" })

        fixture.model.renameSite(site, to: "我的甲站")
        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["https://d.example.com"])
        fixture.model.danmakuDisplay = DanmakuDisplayConfig(fontScale: 1.3, opacity: 0.6, speed: .fast, area: .half)
        fixture.model.subtitleDisplay = SubtitleDisplayConfig(isVisible: false, fontScale: 1.3, position: .high, background: .solid)
        fixture.model.rememberSearch("关键字")
        fixture.model.discoverSiteKey = "b"
        fixture.model.searchSiteKey = "a"

        // 同一份存档、另一个模型：值都该还在。
        // 这条能成立，靠的是「所有读写都走注入的 defaults」（M08f 之前写入写死在 UserDefaults.standard，
        // 那样的「隔离存档」是假的：写出去落进真存档，自己又回读不到）。
        let reopened = try fixture.reopenedModel()

        #expect(reopened.configURL == fixture.model.configURL)
        #expect(reopened.siteNamesForCurrentConfig["a"] == "我的甲站")
        #expect(reopened.danmakuAPI.filledAddresses == ["https://d.example.com"])
        #expect(reopened.danmakuDisplay == DanmakuDisplayConfig(fontScale: 1.3, opacity: 0.6, speed: .fast, area: .half))
        #expect(reopened.subtitleDisplay
            == SubtitleDisplayConfig(isVisible: false, fontScale: 1.3, position: .high, background: .solid))
        #expect(reopened.searchHistory == ["关键字"])
        #expect(reopened.discoverSiteKey == "b")
        #expect(reopened.searchSiteKey == "a")
    }

    @Test("广告清理规则（M06d）：配置载入后**开了的**规则进了 store；没写 enabled 的不进")
    func hlsAdRuleWiring() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        // 配置必须至少有一个站点：`decodeConfig` 把「没有站点」当配置错误（configHasNoUsableSite）。
        await fixture.load("""
        {"sites":[{"key":"a","name":"甲站","type":3,"api":"http://127.0.0.1:9988/spider/a"}],
         "hlsRules":[{"id":"r.on","name":"开了的","enabled":true,
                      "playlistHostSuffixes":["video.example.com"],
                      "hostSuffixes":["ads.example.com"],"minimumSignals":1},
                     {"id":"r.off","name":"没写的",
                      "playlistHostSuffixes":["video.example.com"],
                      "hostSuffixes":["ads.example.com"],"minimumSignals":1}]}
        """)

        // `enabled=true` 的那条编出来进 store（`/m3u8` 每请求现读这里）；没写的按「没开」跳过
        #expect(fixture.model.adRuleStore.current.count == 1)
        #expect(fixture.model.adRuleStore.current.first?.id == "r.on")
    }

    @Test("弹幕（M08c）：开关关着 / 没填地址时**不发请求**且不显示状态行")
    func danmakuGuardsDoNotFetch() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        await fixture.model.loadDanmaku(DanmakuRequest(name: "片名", episode: "第1集"))
        #expect(fixture.model.danmakuStatus == .idle)
        #expect(fixture.model.danmakuLines.isEmpty)

        fixture.model.danmakuAPI = DanmakuAPIConfig(isEnabled: true, addresses: ["", ""])
        await fixture.model.loadDanmaku(DanmakuRequest(name: "片名", episode: "第1集"))
        #expect(fixture.model.danmakuStatus == .idle)
    }

    @Test("多配置入口（urls）：取出来给界面说清原因、只留非空项，且**不会自己去加载**（M18P1）")
    func configSubURLsAreExposed() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }

        // 多仓配置的样子：只有 urls，没有 sites
        await fixture.load("""
        {"urls":["https://a.example/1.json","   ","https://b.example/2.json"]}
        """)

        #expect(fixture.model.configSubURLEntries.map(\.raw) == ["https://a.example/1.json", "https://b.example/2.json"])
        // 内联配置没有基准地址，但这两条是绝对地址，所以都点得动（url 非 nil）。
        #expect(fixture.model.configSubURLEntries.allSatisfy { $0.url != nil })
        #expect(fixture.model.sites.isEmpty)
        // 告警里要说清「不支持多配置入口」——否则用户只会看到「没有可用站点」
        let warned = fixture.model.warnings.contains { $0.contains("多配置入口") }
        #expect(warned)
        // 没有自己去把子配置加载进来（状态仍是这份配置）。
        // 注意：原始数组就是 3 条（含那条空白）—— 过滤只发生在 `configSubURLs` 那一层。
        #expect(fixture.model.state.loadedSource?.config.urls.count == 3)
    }

    @Test("聚合搜索先吐缓存那份：同一部片重搜不再从零等（M28P5「从已经缓存的站点搜索」）")
    func aggregateSearchServesCachedSitesFirst() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model
        await fixture.load()

        let cached = (1 ... 3).map { VodItem(vodID: "v\($0)", vodName: "狂王 \($0)") }
        await model.searchCache.store(cached, forSiteKey: "a", keyword: "狂王")

        var first: AggregateSearchOutcome?
        for await outcome in model.searchAcrossSites(keyword: "狂王") {
            if first == nil {
                first = outcome
            }
        }

        let outcome = try #require(first)
        let seeded = try #require(outcome.sections.first)
        #expect(seeded.site.key == "a", "第一份就该带上缓存过的那个站点（一字节网络都不用发）")
        #expect(seeded.items.count == 3)
    }
}
