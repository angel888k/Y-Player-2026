import CatVodCore
import Foundation

/// 聚合搜索（M11 聚合海报墙）里「一个站点 + 它搜到的条目」。
///
/// 左栏一行 = 一个 section（站点名 + 命中数）；右栏的格子从它的 `items` 来 ——
/// 「全部」那一档就是把所有 section 的 items 摞起来（在 `AggregateSearchView` 里做）。
struct AggregateSearchSection: Identifiable {
    /// 站点：点海报进详情时要用它。
    let site: Site
    /// 左栏显示的站点名：自定义名 > 原始名 > key（见 `AppModel.siteDisplayName(for:)`）。
    let siteName: String
    let items: [VodItem]

    var id: String { site.key }
    var count: Int { items.count }
}

/// 聚合搜索的两条规则（纯逻辑、有单测）：**搜哪些站点**、**结果怎么归位**。
///
/// 为什么单拎出来：这两条决定「墙画出来是什么」；而且并发回来的顺序是乱的，
/// 归位规则钉住才好测（与 `DiscoverPaging` / `SiteSelection` 同一个做法）。
enum AggregateSearchRules {
    /// **能搜**的站点（保持站点清单的顺序）：可运行 + 允许搜索。
    ///
    /// `searchable` 的三态口径与换源一致（`0` 永久关、`1` 开、`2` 临时关但仍可用）。
    static func searchableSites(sites: [Site]) -> [Site] {
        sites.filter { $0.availability.isAvailable && $0.searchAvailability.isUsable }
    }

    /// 聚合搜索**实际参与**的站点：能搜的（``searchableSites(sites:)``）**减掉用户关掉的**。
    ///
    /// 两个入口共用这一条：搜索页与详情页 🔍 的海报墙；开关状态存在 `AppModel.searchExcludedSiteKeys`。
    static func enabled(sites: [Site], excluding excludedKeys: Set<String>) -> [Site] {
        searchableSites(sites: sites).filter { !excludedKeys.contains($0.key) }
    }

    /// 站点不能参与聚合搜索的原因；能参与返回 nil（「筛选站源」面板据此把那行开关置灰并写明原因）。
    static func searchDisabledReason(_ site: Site) -> String? {
        if !site.availability.isAvailable {
            return site.availability.reason ?? "当前平台跑不了这个站点"
        }
        if !site.searchAvailability.isUsable {
            return "配置里关了搜索（searchable = 0）"
        }
        return nil
    }

    /// **首轮**搜几个站点（上限）。
    ///
    /// 为什么要有它（用户报「搜索影视的速度还是慢」）：主接口（kstore 那类）实测有 96 个站点，
    /// **一个都没标** `indexs` —— 上面那条回落规则于是退化成「96 个一起发」。慢站点（那个接口里
    /// 好几个站点 15 秒才超时）会把连接池占满，快站点排在后面干等，整面墙十几到几十秒才陆续有内容。
    /// 首轮只取前 N 个（照站点清单顺序）：这一轮的任务是「先给人看」，几秒内该有东西。
    /// 一个都没搜到时，补搜轮会把其余的接着搜完（见 `AppModel.searchAcrossSites`）——覆盖率不变。
    static let firstRoundLimit = 12

    /// 补搜轮最多再搜几波（每波 ``firstRoundLimit`` 个站点）。
    ///
    /// 为什么要它（M28P11，用户第三次报「搜索影视的速度还是慢」）：实测主接口 96 个站点里
    /// 一半是慢站点 / 死站点（15 秒才超时、有的干脆悬着），而**标了 `indexs` 的只有 2 个**
    /// （「豆瓣|首页」「日期:…」——它们对任意关键词都在几毫秒内返回**空列表**）。
    /// 于是每次搜索都要走「首轮 2 个（秒回、零命中）→ 补搜轮把剩下 94 个全扫一遍」：
    /// 界面上的「搜索中」要挂到一整轮扫完才结束（分钟级），这就是「还是慢」。
    static let fallbackWaveLimit = 3

    /// 墙上有几个站点命中就够「挑入口」了：够数就停止补搜（剩下的站点下次再搜）。
    static let enoughHitSites = 3

    /// 补搜轮还要不要接着搜（**纯函数**，有单测）：够用就停。
    ///
    /// - Parameters:
    ///   - hitSiteCount: 现在墙上有几个站点命中；
    ///   - wavesSearched: 补搜轮已经搜了几波；
    ///   - remainingSites: 还没搜过的站点数（0 = 没什么可搜的了）。
    static func shouldContinueFallback(hitSiteCount: Int, wavesSearched: Int, remainingSites: Int) -> Bool {
        guard remainingSites > 0, wavesSearched < fallbackWaveLimit else {
            return false
        }
        return hitSiteCount < enoughHitSites
    }

    /// **首轮**搜哪些站点，保持站点清单的顺序：
    ///
    /// 1. 先取 ``searchableSites(sites:)``；
    /// 2. 其中有站点标了 `indexs == 1`（上游语义：**索引站点，参与聚合搜索**）就先只搜这些；
    /// 3. 一个都没标就用全部可搜站点 —— 新配置常常没人标 `indexs`，回落总比空墙好；
    /// 4. 最后再截 ``firstRoundLimit`` 个：不截的话 96 个站点会把本机宿主与连接池堵死（见上）。
    ///
    /// 索引站点**一条都没搜到**时还要补搜其余可搜站点 —— 那一层在
    /// `AppModel.searchAcrossSites(keyword:)` 里（它要拿请求结果才决定），不在这条纯规则里。
    static func targets(sites: [Site]) -> [Site] {
        let searchable = searchableSites(sites: sites)
        let indexed = searchable.filter { $0.indexs == 1 }
        let round = indexed.isEmpty ? searchable : indexed
        return Array(round.prefix(firstRoundLimit))
    }

    /// 左栏要的站点串：**只留有命中的站点**（参考图左栏只列有东西的站点），
    /// 顺序照站点清单 —— 并发谁先回来不该决定界面顺序。
    ///
    /// - Parameters:
    ///   - sites: 参与搜索的站点（``targets(sites:)`` 的结果）。
    ///   - hits: 站点 key → 该站点搜到的条目；**失败与零命中都不进列表**（best-effort，与换源一个口径）。
    ///   - names: 站点 key → 展示名；缺失时回落站点原名，名字也空就回落 key。
    static func sections(
        sites: [Site],
        hits: [String: [VodItem]],
        names: [String: String] = [:]
    ) -> [AggregateSearchSection] {
        sites.compactMap { site in
            guard let items = hits[site.key], !items.isEmpty else {
                return nil
            }
            let name = names[site.key] ?? (site.name.isEmpty ? site.key : site.name)
            return AggregateSearchSection(site: site, siteName: name, items: items)
        }
    }
}
