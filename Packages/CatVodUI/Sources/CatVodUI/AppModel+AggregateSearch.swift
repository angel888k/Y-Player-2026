import CatVodCore
import CatVodSource
import Foundation

/// 聚合搜索的结果（+ 诊断）：**逐站回报**，先到的先上墙（M28 首验之二十三）。
struct AggregateSearchOutcome {
    /// 有命中的站点（左栏 + 右栏的数据源）。
    let sections: [AggregateSearchSection]
    /// 参与本轮搜索的站点数（**全部可搜站点**，M28P15）—— 左栏「全部 (命中/参与)」与进度「已回 n/m」的分母。
    let searchedCount: Int
    /// **已回报**的站点数（含失败）—— 界面「已回 n/m」的进度分子。
    let reportedCount: Int
    /// 失败站点的可读原因（`站点名：原因`）。模型侧诊断留着，**界面按用户口径不再显示**
    /// （连接不上的站点不上墙、只显示搜到的）。
    let failures: [String]
}

extension AppModel {
    /// 聚合搜索**实际会用的站点**：能搜的（可运行 + 允许搜索）减掉用户在「筛选站源」里关掉的。
    ///
    /// 搜索页与详情页 🔍 的海报墙都从这里取站点范围 —— 一个开关管两处。
    var searchEnabledSites: [Site] {
        AggregateSearchRules.enabled(sites: sites, excluding: searchExcludedSiteKeys)
    }

    /// 聚合搜索（M11 片 5 的聚合海报墙）：并发搜参与聚合的站点，**逐站回报**（M28 首验之二十三）。
    ///
    /// 返回一条流：**每站回来吐一份「目前已收到的」**（最后一次就是最终结果）。首版是等两轮
    /// （首轮 + 可能补搜的兜底轮）全部跑完才返回一份 —— 任一站点慢 / 连不上（到 `site.timeout`）
    /// 都拖住整面墙，用户报「搜索一个影视半天不出来」。消费端离开 / 换关键词时流结束即取消
    /// 生产（挂在流的 `onTermination` 上），在飞的请求随之取消。
    ///
    /// 口径（与别的搜索刻意不同，写下来免得被「顺手统一」）：
    /// - **先吐缓存那份**（M28P5，用户口径「从已经缓存的站点搜索」）：首轮站点里凡是有
    ///   `站点 + 关键词` 命中缓存的，**一字节网络都不发**先把它们回报出去（墙面立刻有内容），
    ///   实时那轮照旧跑 —— 有新结果就覆盖，失败 / 这次零命中就把缓存那份摘掉；
    /// - 站点范围：``AggregateSearchRules/targets(sites:)`` —— **全部可搜站点**（M28P15，用户口径
    ///   「并发搜索接口的所有站点」）：索引站点排最前（它们通常秒回），其余照站点清单顺序接着进流水线；
    /// - **逐站 best-effort**：某站失败只跳过它、不拖累别的站点；失败原因模型侧留着诊断，
    ///   界面按用户口径**不上墙**（连接不上的站点不显示、只显示搜到的）；
    /// - 每站只取**第一页**：这面墙是「挑一个入口」用的，不是浏览器（要翻页去搜索页）；
    /// - 取图走搜索页同一套 `PictureFiller`：墙上的海报与搜索页看到的应该是同一张。
    func searchAcrossSites(keyword: String) -> AsyncStream<AggregateSearchOutcome> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                await runSearch(keyword: keyword) { outcome in
                    _ = continuation.yield(outcome)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 搜索本体：`report` 每站叫一次（逐站回报；最后一次即最终结果）。
    private func runSearch(
        keyword: String,
        report: (AggregateSearchOutcome) -> Void
    ) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 站点范围 = 能搜的 − 「筛选站源」里关掉的（两个入口共用这一条，见 searchEnabledSites）。
        let allSearchable = searchEnabledSites
        guard !trimmed.isEmpty, !allSearchable.isEmpty else {
            // 边角也要回报一份：消费端靠「至少一份」收尾（空态文案用它）。
            report(AggregateSearchOutcome(
                sections: [],
                searchedCount: allSearchable.count,
                reportedCount: 0,
                failures: []
            ))
            return
        }
        let client = makeSiteClient()
        let filler = makePictureFiller()
        // 展示名先取齐（一次到位）：`note` / `settle` 里就只剩局部量，不碰主 actor 状态。
        let names = Dictionary(
            allSearchable.map { ($0.key, siteDisplayName(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        // 「参与」= **全部可搜站点**（M28P15，用户口径：搜索要覆盖接口的所有站点）——
        // 进度行「已回 n/m」的分母就是这个数，逐站回报时 n 往上走。
        var searchedKeys = Set(allSearchable.map(\.key))
        var hits: [String: [VodItem]] = [:]
        var failuresByKey: [String: String] = [:]
        var reportedCount = 0

        // 缓存那份先上墙（见本函数文档第一条；M28P13 起**跨全部可搜站点**去找）：
        // 有缓存的站点（≤10 分钟）直接上墙（它们本来就在「参与」里）—— 重搜同一部片时
        // 墙上一开始就有内容，网络那轮照旧跑（有新结果覆盖、零命中摘掉）。
        let cachedHits = await searchCache.hits(forSiteKeys: allSearchable.map(\.key), keyword: trimmed)
        if !cachedHits.isEmpty {
            hits = cachedHits
            searchedKeys.formUnion(cachedHits.keys)
            report(settle())
        }

        /// 把「目前已收到的」结算成一份 outcome：逐站回报与最终那份共用同一条。
        func settle() -> AggregateSearchOutcome {
            // 归位顺序统一照**站点清单**：并发谁先回来都不算数。
            let searchedSites = allSearchable.filter { searchedKeys.contains($0.key) }
            let failures = searchedSites.compactMap { site -> String? in
                guard let reason = failuresByKey[site.key] else {
                    return nil
                }
                return "\(names[site.key] ?? site.key)：\(reason)"
            }
            return AggregateSearchOutcome(
                sections: AggregateSearchRules.sections(sites: searchedSites, hits: hits, names: names),
                searchedCount: searchedSites.count,
                reportedCount: reportedCount,
                failures: failures
            )
        }

        /// 单站收尾：记账，然后把「目前已收到的」回报一次（先到先上墙）。
        func note(_ outcome: SiteSearchOutcome) async {
            reportedCount += 1
            if let failure = outcome.failure {
                failuresByKey[outcome.key] = failure
                // 失败**不动** hits：上面那份缓存命中留着（一次连不上不该把墙清空）。
            } else if outcome.items.isEmpty {
                // 这次一个也没搜到：把缓存那份摘掉 —— 不然墙会一直摆着过期命中。
                hits[outcome.key] = nil
            } else {
                hits[outcome.key] = outcome.items
                // 命中写进缓存：下一轮重搜先拿它上墙（见 ``SearchResultCache``）。
                await searchCache.store(outcome.items, forSiteKey: outcome.key, keyword: trimmed)
            }
            report(settle())
        }

        // 总时长预算：一次搜索从这一刻起算（到点后不再开新站点、在飞的等它们回来 —— 见 `searchRound`）。
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(AggregateSearchRules.searchTimeLimit)
        // 站点范围 = **全部可搜站点**（M28P15，用户口径「并发搜索接口的所有站点」）：
        // `targets` 把索引站点排到最前（它们通常秒回），其余照站点清单顺序接着进流水线；
        // 谁先回来谁先上墙（逐站回报），慢站点只占它自己那一格、由总预算兜底。
        await searchRound(
            trimmed,
            sites: AggregateSearchRules.targets(sites: allSearchable),
            client: client,
            filler: filler,
            deadline: deadline,
            onSite: note
        )
        report(settle())
        // 诊断（M28P15）：把「这一轮到底搜了多少站点」钉进日志（用户 Mac 上 `grep 聚合搜索` 可核对）。
        SearchTrace.noteFinished(
            sites: allSearchable.count,
            reported: reportedCount,
            hitSites: hits.count,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
            concurrency: AggregateSearchRules.concurrentLimit,
            requestTimeoutSeconds: AggregateSearchRules.searchRequestTimeoutSeconds
        )
    }

    /// 一圈搜索：**并发打**这些站点（同时在飞的站点数封顶 ``AggregateSearchRules/concurrentLimit``），
    /// 每站回来立刻回报一次（逐站 best-effort；失败只记账，不拖累别的站点）。
    ///
    /// 为什么是「填满在飞的额度、谁回来补谁」而不是「一批一批等齐」（M28P15）：一批里只要有一个
    /// 慢站点（15 秒超时那一档、甚至悬着），这一批的**所有**空位都得等它 —— 96 个站点会变成一串
    /// 「等最慢的那个」的串行。这里改成流水线：一个回来就马上补下一个进去，慢站点只占它自己那一格。
    ///
    /// - Parameter deadline: 到点后不再补新的站点（在飞的等它们回来）—— 保证一轮搜索总能收尾。
    private func searchRound(
        _ keyword: String,
        sites: [Site],
        client: SiteClient,
        filler: PictureFiller,
        deadline: Date,
        onSite: (SiteSearchOutcome) async -> Void
    ) async {
        // 诊断（M28P17）：记「全部开搜 / 末站回报」两个时刻 —— 墙钟的尾巴到底在网络还是在回填，
        // 一眼看出来（见 `SearchTrace.noteRound`）。
        let roundStart = Date()
        var startedAllMs: Int?
        var receivedAllMs: Int?
        await withTaskGroup(of: SiteSearchOutcome.self) { group in
            var next = 0
            // 先把在飞额度填满（流水线：一个回来就补下一个 —— 不是「一批等齐」，见上面的说明）。
            while next < sites.count, next < AggregateSearchRules.concurrentLimit {
                let site = sites[next]
                next += 1
                group.addTask { await Self.searchOneSite(site, keyword: keyword, client: client, filler: filler) }
            }
            if next >= sites.count {
                startedAllMs = Self.milliseconds(since: roundStart)
            }
            for await outcome in group {
                // 先记「到达」再处理：到达时刻才是网络尾巴；刷墙回报的开销不该算进去（M28P18）。
                receivedAllMs = Self.milliseconds(since: roundStart)
                await onSite(outcome)
                // 预算内就补下一个（到点就不补了，在飞的照旧等回来）。
                guard next < sites.count, !Task.isCancelled,
                      AggregateSearchRules.shouldStartAnotherSite(now: Date(), deadline: deadline)
                else {
                    continue
                }
                let site = sites[next]
                next += 1
                group.addTask { await Self.searchOneSite(site, keyword: keyword, client: client, filler: filler) }
                if next >= sites.count {
                    startedAllMs = Self.milliseconds(since: roundStart)
                }
            }
        }
        SearchTrace.noteRound(sites: sites.count, startedAllMs: startedAllMs, receivedAllMs: receivedAllMs)
    }

    /// 从某一刻到现在的毫秒数（诊断用）。
    private nonisolated static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// 搜一个站点：命中带回条目；失败只带回一句可读原因（逐站 best-effort）。
    ///
    /// `nonisolated static` 的理由：它要能进 `group.addTask` 的 `@Sendable` 闭包 ——
    /// 那个闭包里**不能碰 `self`**（`AppModel` 是 `@MainActor` 类、不是 `Sendable`），
    /// 所以做成静态、需要的四个值都由参数带进去。
    private nonisolated static func searchOneSite(
        _ site: Site,
        keyword: String,
        client: SiteClient,
        filler: PictureFiller
    ) async -> SiteSearchOutcome {
        do {
            let found = try await client.search(
                site: site,
                keyword: keyword,
                timeoutSeconds: AggregateSearchRules.searchTimeout(for: site)
            )
            let filled = await filler.fill(site: site, result: found)
            return SiteSearchOutcome(key: site.key, items: filled.list, failure: nil)
        } catch {
            // 只把**可读文案**带过任务边界（`Error` 不保证 `Sendable`，与 `AggregateParser` 同一做法）。
            return SiteSearchOutcome(key: site.key, items: [], failure: userFacingMessage(error))
        }
    }
}

/// 单个站点的搜索结果（内部用）：要么有命中，要么带一条可读的失败原因。
private struct SiteSearchOutcome: Sendable {
    let key: String
    let items: [VodItem]
    let failure: String?
}
