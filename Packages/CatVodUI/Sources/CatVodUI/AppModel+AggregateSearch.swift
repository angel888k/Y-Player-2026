import CatVodCore
import CatVodSource
import Foundation

/// 聚合搜索的结果（+ 诊断）：**逐站回报**，先到的先上墙（M28 首验之二十三）。
struct AggregateSearchOutcome {
    /// 有命中的站点（左栏 + 右栏的数据源）。
    let sections: [AggregateSearchSection]
    /// 参与本轮搜索的站点数（首轮 + 可能补搜的第二轮）—— 左栏「全部 (命中/参与)」的分母。
    let searchedCount: Int
    /// **已回报**的站点数（含失败）—— 界面「已回 n/m」的进度分子。
    let reportedCount: Int
    /// 失败站点的可读原因（`站点名：原因`）。模型侧诊断留着，**界面按用户口径不再显示**
    /// （连接不上的站点不上墙、只显示搜到的）。
    let failures: [String]
    /// 索引站点首轮零命中后是否补搜了其余可搜站点。
    let didFallBackToAllSites: Bool
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
    /// - 站点范围：``AggregateSearchRules/targets(sites:)``（索引站点优先）——
    ///   **首轮一条都没搜到时补搜其余可搜站点**：空墙不等于「别的站点没有」，这面墙是给人挑入口用的；
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
        let indexed = allSearchable.filter { $0.indexs == 1 }
        let firstRound = indexed.isEmpty ? allSearchable : indexed
        guard !trimmed.isEmpty, !firstRound.isEmpty else {
            // 边角也要回报一份：消费端靠「至少一份」收尾（空态文案用它）。
            report(AggregateSearchOutcome(
                sections: [],
                searchedCount: firstRound.count,
                reportedCount: 0,
                failures: [],
                didFallBackToAllSites: false
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
        var searchedKeys = Set(firstRound.map(\.key))
        var hits: [String: [VodItem]] = [:]
        var failuresByKey: [String: String] = [:]
        var reportedCount = 0
        var didFallBack = false

        /// 把「目前已收到的」结算成一份 outcome：逐站回报与最终那份共用同一条。
        func settle() -> AggregateSearchOutcome {
            // 归位顺序统一照**站点清单**：首轮与补搜轮谁先回来都不算数。
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
                failures: failures,
                didFallBackToAllSites: didFallBack
            )
        }

        /// 单站收尾：记账，然后把「目前已收到的」回报一次（先到先上墙）。
        func note(_ outcome: SiteSearchOutcome) {
            reportedCount += 1
            if let failure = outcome.failure {
                failuresByKey[outcome.key] = failure
            } else if !outcome.items.isEmpty {
                hits[outcome.key] = outcome.items
            }
            report(settle())
        }

        await searchRound(trimmed, sites: firstRound, client: client, filler: filler, onSite: note)
        if !Task.isCancelled, hits.isEmpty, !indexed.isEmpty, indexed.count < allSearchable.count {
            // 索引站点一条都没有：把其余的也搜一遍（顺序照站点清单，最后一起归位）。
            let rest = allSearchable.filter { !searchedKeys.contains($0.key) }
            if !rest.isEmpty {
                searchedKeys.formUnion(rest.map(\.key))
                didFallBack = true
                await searchRound(trimmed, sites: rest, client: client, filler: filler, onSite: note)
            }
        }
        report(settle())
    }

    /// 一轮并发搜索：**每站回来就回报一次**（逐站 best-effort；失败只记账，不拖累别的站点）。
    private func searchRound(
        _ keyword: String,
        sites: [Site],
        client: SiteClient,
        filler: PictureFiller,
        onSite: (SiteSearchOutcome) -> Void
    ) async {
        await withTaskGroup(of: SiteSearchOutcome.self) { group in
            for site in sites {
                group.addTask {
                    do {
                        let found = try await client.search(site: site, keyword: keyword)
                        let filled = await filler.fill(site: site, result: found)
                        return SiteSearchOutcome(key: site.key, items: filled.list, failure: nil)
                    } catch {
                        // 只把**可读文案**带过任务边界（`Error` 不保证 `Sendable`，与 `AggregateParser` 同一做法）。
                        return SiteSearchOutcome(key: site.key, items: [], failure: userFacingMessage(error))
                    }
                }
            }
            for await outcome in group {
                onSite(outcome)
            }
        }
    }
}

/// 单个站点的搜索结果（内部用）：要么有命中，要么带一条可读的失败原因。
private struct SiteSearchOutcome: Sendable {
    let key: String
    let items: [VodItem]
    let failure: String?
}
