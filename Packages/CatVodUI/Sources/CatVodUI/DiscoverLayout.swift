import CatVodCore

// 本文件从 M02P16 起用到 `CGFloat`（Tab 栏收放的手势位移）。Swift 不会传递依赖的 import，
// 所以这里显式带上 Foundation（Darwin 上它 re-export CoreGraphics，`CGFloat` 出于此）。
import Foundation
// 本文件在 M28 首验之二十九之后还放了 ``BookTabBarHider``（`ViewModifier`）与
// ``DiscoverTabBarGate``（`ObservableObject`）—— 都要 SwiftUI。
import SwiftUI

// 发现页（`HomeView`）的纯逻辑：翻页判定、筛选行模型、站点切换面板的行模型、底部 Tab 栏的收放、内容合并（分类条保护）。
// 搜索页也复用这里的 `SiteSelection`（站点选择还原）与 `DiscoverSiteList`（站点面板的行模型）。
//
// 刻意与视图分开：参考录屏里有几处「看不见的分支」——
// 上游不给 `pagecount` 时要靠「返回空列表」停下上拉加载、上游没给筛选名时不出左侧标签列、
// 站点名为空时面板与按钮都要回落 `key`。这类分支在真机上很难手工造出来，只有纯函数才方便单测覆盖。
// 底部 Tab 栏的收放（M02P16）同样如此：它由**触摸**驱动，而「手指还在不在屏幕上」这件事
// 在真机上没法手工造出稳定序列，只能把状态机抽出来跑。

/// 发现页的翻页判定。
///
/// 对齐参考录屏：发现页**没有**「上一页 / 下一页」按钮，滚动到底部自动接着加载，
/// 所以「还能不能加载」必须判断得可靠 —— 判错就是无限请求空页。
enum DiscoverPaging {
    /// 是否还能继续加载下一页。
    ///
    /// - `reachedEnd`：上次请求返回了空列表（上游分页到底，且它没给 `pagecount`）；
    /// - `itemCount == 0`：首屏还没有内容（由加载态负责），此时不翻页；
    /// - `pageCount <= 0`：上游没给总页数，只能靠 `reachedEnd` 停。
    static func canLoadMore(page: Int, pageCount: Int, itemCount: Int, reachedEnd: Bool) -> Bool {
        guard !reachedEnd, itemCount > 0 else {
            return false
        }
        return pageCount <= 0 || page < pageCount
    }
}

/// 发现页「这次加载还算不算数」的代次账（M28 首验之三十二）。
///
/// 为什么需要它：`loadHome` / `loadCategory` / `loadMore` / `loadSections` 都是
/// 「发起 → await → 写状态」。写之前用户可能已经换了站点 / 换了分类，或者又发起了更新的一次
/// 加载；旧请求晚到的结果如果照写，会：
///
/// - 把已经正常的页面**涂上一条过期红字**（用户报的「站点加载正常却显示网络报错」）；
/// - 或把新内容**整页盖回旧内容**（快速连点分类 / 筛选时看得见）。
///
/// 规则：`begin()` 占一个新号；`invalidate()` 让所有在飞的号作废（换站点 / 换接口时用）；
/// 写状态前 `isCurrent(_:)` 不为真就整段丢弃 —— 不重试、不提示，「新的那次」会给出最终状态。
struct DiscoverLoadEpoch {
    private(set) var current = 0

    /// 占一个新号（每次发起加载）。
    mutating func begin() -> Int {
        current += 1
        return current
    }

    /// 作废所有在飞的加载（换站点 / 换接口 / 清空内容）。
    mutating func invalidate() {
        current += 1
    }

    /// 这个号还是不是当前号。
    func isCurrent(_ epoch: Int) -> Bool {
        epoch == current
    }
}

/// 发现页的**内容合并**：分类 / 翻页响应落回 `result` 前的保护规则。
///
/// 为什么要有它：分类条（`class`）与筛选行（`filters`）的数据都由**首页**响应提供，
/// 而分类接口**两头都不带**（实测「玩偶」系接口）。旧写法是整页替换 —— 第一次进分类就把
/// 分类条和筛选行抹掉了，表现是「闪一下就不见了」。规则与 ``HomeView/appendPage(_:number:)``
/// 一致：**上游给了就用上游的（可能改名 / 改序），没给就保持原样**。
enum DiscoverContentMerge {
    /// 用 `incoming` 替换 `current` 的内容；`incoming` 没带分类 / 筛选时沿用 `current` 的。
    static func content(preservingCategories incoming: SpiderResult, current: SpiderResult) -> SpiderResult {
        var next = incoming
        if !incoming.hasCategories {
            next.categories = current.categories
        }
        if incoming.filters.isEmpty {
            next.filters = current.filters
        }
        return next
    }
}

/// 发现页的一行筛选（参考视频：左侧筛选名 + 右侧一串胶囊）。
///
/// 上游 `filters` 的 `name` 可能为空，参考录屏里两种形态都出现过：
/// 「木偶剧集」每行都有名字（剧情 / 地区 / 语言 / 时间），「玩偶」源则只有胶囊没有名字。
/// 这里原样保留上游数据，由 `showsName` 决定要不要那一列。
struct DiscoverFilterRow: Hashable, Identifiable {
    /// 提交参数名（放入 `extend`）。
    var key: String
    /// 上游给的显示名；可为空。
    var name: String
    /// 可选值。
    var values: [VodFilterValue]
    /// 当前选中值：优先用户已选，其次上游 `init`。
    var selectedValue: String

    var id: String { key }

    /// 是否显示左侧的筛选名。
    var showsName: Bool {
        !name.isEmpty
    }

    /// 从上游 `filters` 与用户已选值构造回显模型。
    ///
    /// `selected` 里没有该 `key` 时用上游 `init`，与旧版 Picker 的默认高亮一致
    /// （「全部」这类默认项不会错位）。
    static func rows(filters: [VodFilter], selected: [String: String]) -> [DiscoverFilterRow] {
        filters.map { filter in
            DiscoverFilterRow(
                key: filter.key,
                name: filter.name,
                values: filter.values,
                selectedValue: selected[filter.key] ?? filter.initialValue
            )
        }
    }

    /// 某个可选值是否是当前选中项。
    func isSelected(_ value: VodFilterValue) -> Bool {
        value.value == selectedValue
    }
}

extension VodFilterValue {
    /// 胶囊上显示的文字：上游给了 `n` 就用它，否则退回提交值 `v`。
    var chipTitle: String {
        name.isEmpty ? value : name
    }
}

/// 站点切换面板里的一行。
struct DiscoverSiteRow: Identifiable, Equatable {
    /// 站点 `key`（切换时回传它）。
    var key: String
    /// 行里显示的名字。
    var title: String
    /// 是否是当前站点（右侧打勾）。
    var isSelected: Bool

    var id: String { key }
}

/// 站点面板做「抽标签 / 显示名 / 搜索」需要的**全部输入**。
///
/// 打包成一个 `Hashable` 值，是为了让面板能用 `.task(id:)` 一处盯住所有会影响标签的输入：
/// 改自定义名、换接口（另一套 `groupRules`）—— 任一变化都要重抽标签（抽标签要跑正则，不能每次渲染都算）。
///
/// 「本地开关 / 自建规则」那两个输入**已随设置页那份管理界面一起删除**（2026-10-11）。
struct DiscoverSiteRuleInput: Hashable {
    /// 接口配置里的规则（`SourceConfig.groupRules`）。
    var interfaceRules: [GroupRule] = []
    /// 站点自定义名（站点 key → 名字）。
    var names: [String: String] = [:]
}

/// 站点选择的**还原规则**（发现页 / 搜索页共用：切走再回来、冷启动，选择都不能丢）。
///
/// 优先级：当前视图的选择（还在清单里）> 上次保存的选择（还在清单里）> 首个可用站点。
/// 发现页原来每次都回落首个站点 —— 只要 `syncHomeWithInterface` 再跑一遍（切 Tab 回来 /
/// 接口刷新），用户的切换就没了；搜索页每次 push 都是新实例，同一条规则负责把选择捡回来。
enum SiteSelection {
    /// 解决「这次同步该选中哪个站点」。
    static func resolvedKey(current: String, saved: String, available: [String]) -> String {
        if !current.isEmpty, available.contains(current) {
            return current
        }
        if !saved.isEmpty, available.contains(saved) {
            return saved
        }
        return available.first ?? ""
    }
}

/// 点封面的去向（M28 首验之二十二，用户口径）：**接口的第一个站点**点封面去**搜索页**
/// （自动带片名并搜索这个影视）—— 其余站点照旧进详情。
///
/// 判定单独拿出来放纯函数：站点清单顺序与「第一个是谁」是最容易被改排序时碰坏的东西，
/// 单测盯住它（见 `DiscoverPageTests`）。
enum DiscoverPosterTarget {
    /// 当前选中的站点是不是清单里的第一个。
    static func opensSearch(selectedKey: String, siteKeys: [String]) -> Bool {
        guard let first = siteKeys.first else {
            return false
        }
        return selectedKey == first
    }
}

/// 站点切换面板的行模型与分组（M06e / M06f / M06g）。
///
/// 单测价值：录屏里的面板有三种容易做错的状态 —— 站点名为空、当前站点、站点顺序，
/// 它们在真机上都不好复现（上游配置随时会变），所以把判定放进纯函数。
/// 分组条（从站点名里抽标签）同样放这里：抽错一个标签，整条分组条就歪了。
enum DiscoverSiteList {
    /// 面板要列出的行：**保持上游站点顺序**（面板行序 = 配置里的站点序）。
    ///
    /// `selectedGroup` 非空时只留该分组的站点（点分组条某一项之后）；
    /// `keyword` 非空时按 ``SiteNameRules/matchesSearch(rawName:customName:key:keyword:)`` 过滤（搜索框）。
    static func rows(
        sites: [Site],
        selectedKey: String,
        names: [String: String] = [:],
        tags: [String: [String]] = [:],
        selectedGroup: String = "",
        keyword: String = ""
    ) -> [DiscoverSiteRow] {
        sites
            .filter { matchesSearch(site: $0, names: names, keyword: keyword) }
            .filter { matches(site: $0, tags: tags, selectedGroup: selectedGroup) }
            .map { site in
                DiscoverSiteRow(
                    key: site.key,
                    title: title(for: site, names: names),
                    isSelected: site.key == selectedKey
                )
            }
    }

    /// 站点显示名：上游没给名字时回落 `key`（工具栏按钮与面板用同一口径）。
    ///
    /// 有自定义名时用自定义名 —— 口径落在 `SiteNameRules.displayName`，这里只是转发，
    /// 避免「面板显示一套、抽标签用另一套」。
    static func title(for site: Site, names: [String: String] = [:]) -> String {
        SiteNameRules.displayName(rawName: site.name, customName: names[site.key] ?? "", key: site.key)
    }

    /// 这个站点在不在选中的分组里（`selectedGroup` 为空 = 不筛）。
    static func matches(site: Site, tags: [String: [String]], selectedGroup: String) -> Bool {
        guard !selectedGroup.isEmpty else { return true }
        return tags[site.key]?.contains(selectedGroup) ?? false
    }

    /// 搜索命中（新名 / 原名 / key 任一包含关键词即算 —— 规则在 `SiteNameRules`）。
    static func matchesSearch(site: Site, names: [String: String], keyword: String) -> Bool {
        SiteNameRules.matchesSearch(
            rawName: site.name,
            customName: names[site.key] ?? "",
            key: site.key,
            keyword: keyword
        )
    }

    /// 每个站点从**生效名**（自定义名优先，否则原始名，再否则 `key`）里抽出来的标签；
    /// 抽不出标签的站点不出现在结果里。
    static func tags(sites: [Site], input: DiscoverSiteRuleInput) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for site in sites {
            let values = SiteNameRules.groups(
                rawName: site.name,
                customName: input.names[site.key] ?? "",
                interfaceRules: input.interfaceRules
            )
            if !values.isEmpty {
                result[site.key] = values
            }
        }
        return result
    }

    /// 分组条上要显示的分组：**按站点顺序**收集、去重，再按存的顺序排（对齐上游
    /// `Site.getGroups` 用 `LinkedHashSet` 收集再交给 `SiteGroupOrderStore.sort`）。
    static func groups(sites: [Site], tags: [String: [String]], savedOrder: [String] = []) -> [String] {
        var all: [String] = []
        for site in sites {
            for tag in tags[site.key] ?? [] where !all.contains(tag) {
                all.append(tag)
            }
        }
        return SiteGroupOrder.order(all, savedOrder: savedOrder)
    }
}

/// 发现页底部 Tab 栏的收放状态机（`HomeView` 上的旁听手势驱动它）。
///
/// YG 给的规格（原话，当规格用）：
/// - 向上滑列表 → 收起；
/// - 手指**没离开屏幕** → 保持收起；松手 → 也保持收起；
/// - **再次触碰屏幕** → 展开；再滑 → 再收起。
///
/// 由此得出四条规则，每条都有单测：
/// 1. **只有「触碰」能展开**，往下滑不展开 —— 所以收起是单向动作，松手不回弹；
/// 2. **同一次触摸内不再展开**：手指没离开就一直收起（中途反向滑回来也一样）；
/// 3. 「收起」要有阈值：触屏瞬间先展开，滑过一段才收 —— 不然手指一碰就收，想点顶部工具栏会闪；
/// 4. 判定要**以竖直为主**：横向展示里每段轮播都是内层横滑，横着划会有几 pt 竖直漂移，
///    不排除掉就会「滑轮播把 Tab 栏也收起来」。
///
/// 为什么不读滚动偏移：偏移只能回答「滚到哪了」，回答不了「手指还在不在屏幕上」，
/// 而规则 1、2 恰恰只能由触摸本身判定（能直接给 `isDragging` 的 `onScrollPhaseChange` 要 iOS 18）。
struct DiscoverTabBarVisibility: Equatable {
    /// 收起需要滑过的距离（pt）。
    ///
    /// 取小值是**故意的**（要跟手），但零不行 —— 太小会顺手指出一点抖动就收，太大则有明显滞后。
    static let hideThreshold: CGFloat = 8

    /// 是否收起（`true` = Tab 栏隐藏）。
    private(set) var isHidden = false
    /// 手指是否在屏幕上。
    private(set) var isTouching = false

    /// 手指碰到屏幕：展开。
    ///
    /// 幂等：一次触摸里被反复调用，不会把「已经滑出来的收起」又展开（规则 2）。
    mutating func touchDown() {
        isTouching = true
        isHidden = false
    }

    /// 手指拖动。
    ///
    /// 位移为零的那次事件当作「触屏」处理 —— 零距离拖动手势在触屏瞬间就会发一次零位移
    /// （`HomeView` 上的两个旁听手势之一，用来兜住另一路信号）。已经记录过触摸就忽略，
    /// 免得手指恰好移回原点时把收起的栏又弹出来（规则 2）。
    mutating func dragChanged(translationX: CGFloat, translationY: CGFloat) {
        if translationX == .zero, translationY == .zero {
            if !isTouching {
                touchDown()
            }
            return
        }
        guard isTouching, Self.isUpwardScroll(translationX: translationX, translationY: translationY) else {
            return
        }
        isHidden = true
    }

    /// 手指离开屏幕：**刻意什么都不做** —— 收起状态原样留着（「离开后也隐藏」）。
    ///
    /// 惯性滑动期间没有触摸事件，也就没有状态变化，Tab 栏自然一直是收起的，不必额外处理。
    mutating func touchEnded() {
        isTouching = false
    }

    /// 强制展开：离开发现页时用。
    ///
    /// Tab 栏是「从发现页导航出去的路」，不能带着收起状态离开（否则切回来时人会被困在页面上）。
    mutating func reveal() {
        isHidden = false
        isTouching = false
    }

    /// 这次算不算「向上滑列表」。
    ///
    /// - `translationY < -hideThreshold`：手指向上移（`y` 向下为正）＝ 在往下翻内容；
    /// - `|translationY| > |translationX|`：以竖直为主，横滑轮播不算（规则 4）。
    static func isUpwardScroll(translationX: CGFloat, translationY: CGFloat) -> Bool {
        translationY < -hideThreshold && abs(translationY) > abs(translationX)
    }
}

// MARK: - 收放的「门」与「累计器」（M28 首验之二十九）

/// 底部 Tab 栏收放的**盒子**：只在 `isHidden` 真的翻转时才广播。
///
/// 为什么要它：原来 `HomeView` 用一个 `@State DiscoverTabBarVisibility`，而滚动监听器**每帧**
/// 都要摸它 —— `@State` 一改就重建整页（一屏 `NavigationLink` 每帧重造），模拟器上直接掉到
/// 2~6 帧/拖动。
///
/// **为什么是静态共享、不给任何视图持有**（M28 首验之二十九，上机帧账定案）：只把它从
/// `@State` 换成 `@StateObject` **还不够** —— `@StateObject` 归 `HomeView` 所有，一广播
/// `HomeView.body` 照样重来。帧账证据：0 次重建的拖动全顺、1~2 次的就卡（每次重建 ≈ 50~100ms，
/// 就是 `LazyVGrid` 的 diff）。现在没有任何视图「拥有」它，观察者只有 ``BookTabBarHider``：
/// 广播只重算那一层，滚动内容一次都不再求值。
final class DiscoverTabBarGate: ObservableObject {
    /// 共享实例（发现页的收放只有一份：一个包一份界面）。
    static let shared = DiscoverTabBarGate()
    @Published private(set) var isHidden = false

    /// 判定状态（纯值类型，规格与判定见 ``DiscoverTabBarVisibility``）。
    private var state = DiscoverTabBarVisibility()

    func touchDown() {
        state.touchDown()
        publishIfChanged()
    }

    func dragChanged(translationX: CGFloat, translationY: CGFloat) {
        state.dragChanged(translationX: translationX, translationY: translationY)
        publishIfChanged()
    }

    func touchEnded() {
        state.touchEnded()
        publishIfChanged()
    }

    /// 离开发现页时强制展开。
    func reveal() {
        state.reveal()
        publishIfChanged()
    }

    private func publishIfChanged() {
        guard isHidden != state.isHidden else {
            return
        }
        isHidden = state.isHidden
    }
}

/// 只读 ``DiscoverTabBarGate`` / 沉浸登记簿、据此收放 Tab 栏的**包装视图**。
///
/// 存在的理由：`HomeView.body` 一旦读这些状态，收放变化就要重建整页；收在这里之后，
/// 重建只发生在这一层（内容原样转发）。
struct BookTabBarHider: ViewModifier {
    @ObservedObject var gate: DiscoverTabBarGate
    @EnvironmentObject private var immersiveTabBar: ImmersiveTabBarState
    /// 收放时要不要带动画（诊断档「收栏无动画」会把它关掉 —— 判「系统收栏动画与滚动打架」）。
    var animated = true

    func body(content: Content) -> some View {
        let hidden = gate.isHidden || immersiveTabBar.isActive
        return Group {
            if animated {
                content.adaptiveTabBarHidden(hidden)
            } else {
                content
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .adaptiveTabBarHidden(hidden)
            }
        }
    }
}
