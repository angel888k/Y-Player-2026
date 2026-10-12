import CatVodCore
import SwiftUI

// 发现页的界面件（对齐参考录屏）：分类条 / 筛选条 / 筛选胶囊 / 海报卡 / 站点切换菜单与查找弹层。
//
// 这里只放「纯展示单元」：数据加载与状态在 `HomeView` / `HomeView+Data.swift`，
// 判定逻辑在 `DiscoverLayout.swift`，这样每个件都能在单测里直接构造。

/// 分类条：横向滚动的分类名，当前分类**加粗变黑**（参考视频没有胶囊底，靠字重区分）。
struct DiscoverCategoryStrip: View {
    let categories: [VodCategory]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(categories) { category in
                    Button {
                        onSelect(category.typeID)
                    } label: {
                        Text(category.typeName)
                            .fontWeight(category.typeID == selectedID ? .semibold : .regular)
                            .foregroundStyle(category.typeID == selectedID ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

/// 筛选区：一行一个筛选（左侧名可选）+ 右侧可横向滚动的胶囊。
///
/// ⚠️ **身份一律按位置，不拿上游数据当 `ForEach` 的 id**（2026-10-12 定，用户报「有的系统版本
/// 上筛选点不了」）：上游的 `v` 不保证唯一 —— 实测「蜡笔 / 花卷」的剧情行有**两个「恐怖」**
/// （`v` 都是 `/class/恐怖`）、很多行还带**空 `v` 的「全部」**。`VodFilterValue.id` 是 `v`，
/// 拿它当 id 会撞成重复 id，SwiftUI 的行为在各系统版本上不一致：轻则选中态错位，
/// 重则那一行点不动（复盘见 `docs/任务记录/M28P3-筛选胶囊按位置给身份.md`）。
/// 行也一样：`row.key` 来自上游，重复就同样会撞。
struct DiscoverFilterStrip: View {
    let rows: [DiscoverFilterRow]
    let onSelect: (_ row: DiscoverFilterRow, _ value: String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    if row.showsName {
                        Text(row.name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                DiscoverFilterChip(
                                    title: value.chipTitle,
                                    isSelected: row.isSelected(value)
                                ) {
                                    onSelect(row, value.value)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

/// 筛选胶囊：选中是实心主题色 + 白字，未选中是淡灰底（参考视频的两种态）。
struct DiscoverFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 横向展示里的一个分区（＝ 一个分类的一页内容）。
///
/// 与 `HomeLayout` 的「横向展示」配套：图 1 里每个分区就是「一个分类 + 它的一页海报」。
struct DiscoverSection: Identifiable, Equatable {
    /// 分类 ID（用它排回原顺序、也用它做 `>` 的跳转目标）。
    let id: String
    /// 分区标题（分类名）。
    let title: String
    let items: [VodItem]
}

/// 分区标题：分类名 + 右侧 `>`（参考图 1）。
///
/// `>` 的行为是「选中这个分类并切到**纵向展示**」—— 图 1 里点它，要看的就是那个分类的
/// 完整列表，而完整列表正是纵向模式（分类 + 筛选 + 网格 + 翻页）。不另造一个「分类详情页」：
/// 两者要显示的东西完全一样，多一层就多一处会走样的地方。
struct DiscoverSectionHeader: View {
    let title: String
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }
}

/// 海报卡：封面 + 右上角角标 + 居中片名（参考视频的网格单元）。
struct DiscoverPosterCard: View {
    let item: VodItem
    /// 卡片样式（**站点级**，M23P1）：配置声明了才照做 —— 没声明保持参考视频那个 2:3。
    ///
    /// 条目级样式（`VodItem.style`）**故意不在这里用**：网格里逐卡不同比例会排成锯齿。
    /// 这是排版取舍，不是漏接（协议上的优先级规则在 `CardStyleResolver` 里，由调用方决定用哪一级）。
    var style: CardStyle?

    /// 海报宽高比：配置声明了就用它的，否则参考视频那个 2:3（见 ``PosterCardLayout``）。
    static let aspectRatio: CGFloat = 2.0 / 3.0

    /// 海报图的目标显示尺寸（点）：宽度必给（横向分区 = 固定卡宽；纵向网格 = 估的格宽），
    /// 高度按卡片比例补 —— **刻意不用 `GeometryReader`**（懒容器里几十个会拖垮布局，
    /// 上机帧账抓过单帧 100~170ms）。
    var targetSize: CGSize?

    private var isCircularCard: Bool {
        PosterCardLayout.isCircular(style)
    }

    private var cardRatio: CGFloat {
        PosterCardLayout.ratio(for: style, circular: isCircularCard)
    }

    /// 没给 `targetSize` 时按布局估的格宽（点）：iPhone 端 3 列的典型宽度。
    /// 只影响**解码分辨率**（下采样按最大边，估大一点无妨），不参与排版 —— 排版由外层说了算。
    static let estimatedGridCardWidth: CGFloat = 117

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // 圆形卡（`oval` / `circle=1`）与圆角矩形分开画：
                // iOS 15 没有 `AnyShape`，只能各走各的分支。
                if isCircularCard {
                    Color.secondary.opacity(0.12)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { poster }
                        .clipShape(Circle())
                } else {
                    Color.secondary.opacity(0.12)
                        .aspectRatio(cardRatio, contentMode: .fit)
                        .overlay { poster }
                        .clipShape(RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius))
                }
                if !item.vodRemarks.isEmpty {
                    badge
                }
            }
            Text(item.vodName.isEmpty ? item.vodID : item.vodName)
                .font(.caption)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
    }

    /// 封面；加载中或失败时露出底下的淡灰占位（角标照常显示，与参考视频一致）。
    ///
    /// 用 ``CachedImage``（M28 首验之二十九）：`AsyncImage` 没内存缓存，滚动回收就重下重解，
    /// 一屏海报就能把滑动拖顿 —— 换掉之后回滚不再闪白、不在主线程解大图。
    private var poster: some View {
        CachedImage(
            url: item.vodPic,
            targetSize: targetSize ?? CGSize(width: Self.estimatedGridCardWidth, height: 0),
            aspectRatio: cardRatio
        )
    }

    /// 右上角角标：上游 `vodRemarks`（「更新至 58 集」「全 9 集」「HD」「4K」…）。
    private var badge: some View {
        Text(item.vodRemarks)
            .font(.caption2)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
            .padding(6)
    }
}

/// 左上角「站点切换」图标：参考录屏里是两个开关（上一个空、下一个满）。
///
/// 为什么自己画而不用 SF Symbol：录屏里这个字形在 SF Symbols 里没有对应项，
/// 而它是「点这里切换站点」的唯一提示，画错或画丢都会让人找不到切换入口。
/// （⚠️ 站点名里那个「☁️」不是按钮图标，它是上游给的**站点名自带**的表情。）
struct DiscoverSiteSwitchGlyph: View {
    /// 图标宽度；高度按两个开关的比例自动算。
    var size: CGFloat = 17

    var body: some View {
        VStack(spacing: size * 0.16) {
            Capsule()
                .strokeBorder(Color.accentColor, lineWidth: max(size * 0.11, 1))
                .frame(width: size, height: size * 0.42)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .padding(.leading, size * 0.09)
                }
            Capsule()
                .fill(Color.accentColor)
                .frame(width: size, height: size * 0.42)
                .overlay(alignment: .trailing) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.26, height: size * 0.26)
                        .padding(.trailing, size * 0.09)
                }
        }
        .accessibilityLabel("站点切换")
    }
}

/// 站点切换入口（发现页左上角）：**系统原生菜单**（M28 首验之二十四）。
///
/// 为什么不再自绘悬浮面板：`docs/UI 规范.md` 总则第一条「原生优先，不做跨版本仿制」——
/// 原来那张贴左卡片（手算 2/3 屏宽 + `.regularMaterial` + 圆角阴影 + 透明点击层）在任何
/// 系统上都是同一个样子，等于把一种版本的观感搬到了所有版本上。改成 `Menu` 之后，
/// iOS 15 / iOS 16+ / macOS 各拿各的原生菜单形态 —— 与「换线路」（M07c3）、
/// 「播放历史范围」（M02P11）同一种做法：能被系统控件表达的，就交给系统。
///
/// 菜单里放不下的两件东西各自开原生弹层（不是仿制）：
/// - **搜索**：菜单里没有输入框 → 「查找站点…」开 ``DiscoverSiteFinder``（原生搜索栏的列表）；
/// - **改名**：同上 → 「重命名站点」子菜单先选站点，由上层弹 `.alert` 输入。
///
/// **分组筛选 / 分组排序的菜单项已拆**（用户口径，2026-10-11）：不想要分组，菜单回到
/// 「站点清单 + 查找 + 重命名当前站点」。底层的分组能力（`SiteNameRules.groups` /
/// `SiteGroupOrder` / `model.siteGroupOrder`）**原样保留**，以后想恢复只需把 UI 接回来。
struct DiscoverSiteSwitcher: View {
    let sites: [Site]
    let selectedKey: String
    /// 按钮上的名字（没有可用站点时由上层给「选择站点」）。
    let title: String
    /// 显示名 / 搜索要的自定义名（``DiscoverSiteRuleInput`` 里菜单要用的只剩这一项）。
    var ruleInput = DiscoverSiteRuleInput()
    /// 请求改名（菜单里放不下输入框：由上层弹 `.alert`）。
    ///
    /// **只对当前站点**（M28 首验之二十九）：原来是一层「重命名站点 → 全量站点」子菜单 ——
    /// 嵌套子菜单里再挂几十行，菜单弹出前建树的代价就上来了。改名是低频入口，
    /// 收成一颗「重命名当前站点…」，要改谁先切到谁（切站点本来也是一次点击）。
    var onRenameCurrent: (() -> Void)?
    /// 打开「查找站点」弹层（同上，菜单里放不下输入框）。
    var onFindRequest: (() -> Void)?
    let onSelect: (String) -> Void

    private var rows: [DiscoverSiteRow] {
        DiscoverSiteList.rows(
            sites: sites,
            selectedKey: selectedKey,
            names: ruleInput.names
        )
    }

    var body: some View {
        Menu {
            tools
            siteList
        } label: {
            HStack(spacing: 6) {
                DiscoverSiteSwitchGlyph()
                Text(title)
                    .lineLimit(1)
            }
            .font(.body.weight(.semibold))
        }
        .disabled(sites.isEmpty)
    }

    // MARK: - 菜单内容

    /// 站点清单上面那一组：查找 / 改名。
    ///
    /// 放在**清单前面**是有意的：站点一多，清单会把后面的项推得很深，而「查找站点」正是为长清单
    /// 准备的入口。
    @ViewBuilder
    private var tools: some View {
        if let onFindRequest {
            Button {
                onFindRequest()
            } label: {
                Label("查找站点…", systemImage: "magnifyingglass")
            }
        }
        if let onRenameCurrent {
            Button {
                onRenameCurrent()
            } label: {
                Label("重命名当前站点…", systemImage: "pencil")
            }
        }
    }

    /// 站点清单：一行一个站点，当前站点打勾（与「换线路」菜单同一个写法的对勾）。
    ///
    /// **主菜单只放前 ``menuRowLimit`` 个**（M28 首验之二十九）：站点一多（作者那套配置有几十上百个），
    /// 全量塞进菜单会让「点开那一下」卡 —— 系统要一次性把几百个菜单项建出来。长清单的入口本来就是
    /// 「查找站点…」（菜单里第一条工具项，原生搜索栏）；当前站点**始终在列**（它要么在前段、
    /// 要么被单独补一行），不会因为截断找不到自己。
    private var siteList: some View {
        Section {
            ForEach(menuRows) { row in
                Button {
                    onSelect(row.key)
                } label: {
                    if row.isSelected {
                        Label(row.title, systemImage: "checkmark")
                    } else {
                        Text(row.title)
                    }
                }
            }
            if rows.count > menuRows.count {
                Label("还有 \(rows.count - menuRows.count) 个站点 —— 用「查找站点…」", systemImage: "ellipsis")
            }
        } header: {
            Text("站点")
        }
    }

    /// 主菜单里最多列多少个站点（超过走「查找站点…」）。
    ///
    /// 定 8 是**上机量出来的**：菜单里每多一行，弹出的那一下就更沉一点；8 行 + 当前站点
    /// （最多 9 行）在模拟器上已贴到「系统菜单本身的底噪」附近（同尺寸的最小菜单也一样手感）。
    static let menuRowLimit = 8

    /// 主菜单实际列出的行：前 `menuRowLimit` 个 + **当前站点**（若被截在外面就补上，不重复）。
    private var menuRows: [DiscoverSiteRow] {
        let head = Array(rows.prefix(Self.menuRowLimit))
        guard !head.contains(where: \.isSelected),
              let selected = rows.first(where: \.isSelected)
        else {
            return head
        }
        return head + [selected]
    }
}

/// 「查找站点」弹层（``DiscoverSiteSwitcher`` 菜单里的入口）：菜单里放不下输入框，搜索单独开一层。
///
/// 这一层也是系统原生的一套：导航容器 + 原生搜索栏（`adaptiveSearchable`）+ `List` + 行尾对勾。
/// 命中口径与菜单 / 旧面板一字不差（生效名 / 原名 / 站点 key 任一包含关键词，见 ``SiteNameRules``）；
/// 点一行 = 切到那个站点并收起（切站后的重新加载由调用方统一发起）。
struct DiscoverSiteFinder: View {
    let sites: [Site]
    let selectedKey: String
    /// 显示名 / 搜索要的自定义名。
    var ruleInput = DiscoverSiteRuleInput()
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 搜索关键词（弹层每次打开重来）。
    @State private var keyword = ""

    private var rows: [DiscoverSiteRow] {
        DiscoverSiteList.rows(sites: sites, selectedKey: selectedKey, names: ruleInput.names, keyword: keyword)
    }

    var body: some View {
        AdaptiveNavigationContainer {
            List {
                if rows.isEmpty {
                    Text("没有匹配的站点。")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        onSelect(row.key)
                        dismiss()
                    } label: {
                        rowLabel(row)
                    }
                }
            }
            .adaptiveListStyle()
            .adaptiveSearchable(text: $keyword, prompt: "搜索站点")
            .navigationTitle("查找站点")
            .adaptiveInlineNavigationTitle()
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                Button("取消") {
                    dismiss()
                }
            }
        }
    }

    /// 一行：站点名 + 当前站点行尾打勾（与菜单里的对勾同一个口径）。
    private func rowLabel(_ row: DiscoverSiteRow) -> some View {
        HStack(spacing: 8) {
            Text(row.title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if row.isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
