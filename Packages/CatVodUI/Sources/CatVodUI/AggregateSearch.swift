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

    /// 一次搜索最多**同时**打几个站点（并发上限）。
    ///
    /// 用户口径（M28P15）：「搜索要并发搜接口的**所有**站点」—— 所以这个数字管的是并发，
    /// **不是**「只搜前 N 个」。取 24 的理由（M28P16 实测，本机直跑主接口宿主、95 个站点）：
    /// 12 条时 48 个命中要 ~10 秒才到齐、整轮 20~22 秒收尾；24 条时命中 4 秒内到齐、9.9 秒收尾。
    /// 传输层的每 host 连接数与它对齐（`AppModel.siteSessionConfiguration`）。
    static let concurrentLimit = 24

    /// 聚合搜索里**每站请求**的超时上限（秒）。
    ///
    /// 为什么要有它（M28P16 实测）：整轮的尾巴全是慢站点 / 死站点在站点自己的 15 秒超时上耗着
    /// —— 而**能成功**的站点没有一个需要超过 8 秒（三组对照里没有一个「>8 秒才成功」的站点）。
    /// 压到 8 后同样 48 个命中，整轮墙钟 20~22 秒 → 9.9 秒。
    static let searchRequestTimeoutSeconds = 8

    /// 这个站点在聚合搜索里用的超时（秒）：**不超过** ``searchRequestTimeoutSeconds``；
    /// 站点自己配得更短就听站点的（纯函数，有单测）。
    static func searchTimeout(for site: Site) -> Int {
        min(max(site.timeout, 1), searchRequestTimeoutSeconds)
    }

    /// 一轮搜索的总时长预算（秒）：到点后**不再开新的站点**，在飞的等它们回来。
    ///
    /// 为什么要有个总预算：口径是「搜所有站点」，可主接口里就是有一批慢站点 / 死站点
    /// （实测：15 秒才连接重置、甚至悬着不返回）。没有总预算，一次搜索可能永远收不了尾、
    /// 界面一直挂在「搜索中」；有预算则「到点收工、墙上已有的就是结果」，而且**通常几秒就完**
    /// （并发 + 逐站回报：快的站点第一两秒就上墙了）。
    static let searchTimeLimit: TimeInterval = 30

    /// 还开不开新的一站（**纯函数**，有单测）：`now` 还没到 `deadline` 就开，到了就只等手里的。
    static func shouldStartAnotherSite(now: Date, deadline: Date) -> Bool {
        now < deadline
    }

    /// **先搜**哪些站点（顺序；不代表范围 —— 范围是「所有可搜站点」）：
    ///
    /// 1. 先取 ``searchableSites(sites:)``；
    /// 2. 其中有站点标了 `indexs == 1`（上游语义：**索引站点，参与聚合搜索**）就把它们排在最前；
    /// 3. 一个都没标就照站点清单顺序从头搜。
    ///
    /// 索引站点只是**排前面**：其余的站点由 `AppModel.searchAcrossSites(keyword:)` 接着并发搜完
    /// （用户口径 M28P15：搜索要覆盖接口的所有站点）。
    static func targets(sites: [Site]) -> [Site] {
        let searchable = searchableSites(sites: sites)
        let indexed = searchable.filter { $0.indexs == 1 }
        guard !indexed.isEmpty else {
            return searchable
        }
        // 索引站点在前；其余照原顺序跟在后面。
        let indexedKeys = Set(indexed.map(\.key))
        return indexed + searchable.filter { !indexedKeys.contains($0.key) }
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
