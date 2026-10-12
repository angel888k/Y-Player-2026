import CatVodCore
import Foundation

/// 聚合搜索的**结果缓存**（M28P5，用户口径「从已经缓存的站点搜索」）。
///
/// 为什么加它：那面墙是「挑一个入口」用的，而同一部片经常要搜第二次 —— 从详情页退回来、
/// 换个入口再点 🔍、手滑重搜 —— 原来每次都把每个站点重打一遍，用户看到的就是「搜索还是慢」。
/// 这里把**站点 + 关键词**的命中记下来：重搜**先把缓存那份当场给出去**（墙面立刻有内容），
/// 实时那轮照旧跑（有新结果就覆盖，失败了就留着缓存那份）。
///
/// 只存**命中**：失败与零命中都不进缓存（那是「这次没搜到」，不是「这个站点没有」）。
/// 有效期固定（``lifetime``）：够覆盖「搜 → 进详情 → 回来再搜」这一串，又不会把旧片单挂太久。
///
/// 有意没做（先写下来，免得被「顺手补上」）：
/// - **不落盘**：搜索结果是「此刻这面墙」的东西，跨启动留存该走「首页缓存」那类有设置项的缓存；
/// - **不做设置项**：它只是加速，不是内容策略。
actor SearchResultCache {
    /// 一条缓存：命中的条目 + 写入时间。
    private struct Entry {
        var items: [VodItem]
        var storedAt: Date
    }

    /// 有效期（秒）：10 分钟。
    static let lifetime: TimeInterval = 10 * 60
    /// 条数上限（超出淘汰**最久没写过**的）。
    static let limit = 400

    private var entries: [String: Entry] = [:]

    /// 取一批站点的缓存命中（没有 / 过期的跳过）。
    ///
    /// - Parameter now: 便于单测注入时间（生产用当前时间）。
    func hits(forSiteKeys keys: [String], keyword: String, now: Date = Date()) -> [String: [VodItem]] {
        var result: [String: [VodItem]] = [:]
        for key in keys {
            guard let entry = entries[Self.cacheKey(siteKey: key, keyword: keyword)] else {
                continue
            }
            guard now.timeIntervalSince(entry.storedAt) < Self.lifetime else {
                continue
            }
            result[key] = entry.items
        }
        return result
    }

    /// 记一份命中（空数组不记）。
    func store(_ items: [VodItem], forSiteKey key: String, keyword: String, now: Date = Date()) {
        guard !items.isEmpty else {
            return
        }
        entries[Self.cacheKey(siteKey: key, keyword: keyword)] = Entry(items: items, storedAt: now)
        pruneIfNeeded()
    }

    /// 清空（换接口 / 宿主站点刷新时用：站点集合变了，旧结果没有意义）。
    func removeAll() {
        entries.removeAll()
    }

    /// 当前条数（单测 / 诊断用）。
    func count() -> Int {
        entries.count
    }

    /// 键：**站点 + 归一化关键词**。
    ///
    /// 归一化 = 去首尾空白 + 小写：「Funny / funny」「狂王 /  狂王 」这类差异不该各存一份。
    /// 个别大小写敏感的上游会因此少命中一次缓存 —— 那只是慢一点（照旧走实时搜索），不会错。
    static func normalize(_ keyword: String) -> String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func cacheKey(siteKey: String, keyword: String) -> String {
        "\(siteKey)#\(normalize(keyword))"
    }

    /// 超上限：先丢最久没写过的。
    private func pruneIfNeeded() {
        guard entries.count > Self.limit else {
            return
        }
        let overflow = entries.count - Self.limit
        for key in entries.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(overflow).map(\.key) {
            entries[key] = nil
        }
    }
}
