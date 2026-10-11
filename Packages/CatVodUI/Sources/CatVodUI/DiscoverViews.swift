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
struct DiscoverFilterStrip: View {
    let rows: [DiscoverFilterRow]
    let onSelect: (_ row: DiscoverFilterRow, _ value: String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    if row.showsName {
                        Text(row.name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(row.values) { value in
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

    private var isCircularCard: Bool {
        PosterCardLayout.isCircular(style)
    }

    private var cardRatio: CGFloat {
        PosterCardLayout.ratio(for: style, circular: isCircularCard)
    }

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
    private var poster: some View {
        AsyncImage(url: URL(string: item.vodPic)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
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
/// 分组筛选（M06e）与分组排序（M06g）也收进菜单：筛选是一个带对勾的子菜单（菜单项标题里
/// 带着当前筛的是哪一组），排序是「分组排序 → 每组一节 → 上移 / 下移」。`selectedGroup` 是
/// 菜单内容自己的 `@State`：随菜单每次开合重来（与上游「关掉就忘」一致）。
struct DiscoverSiteSwitcher: View {
    let sites: [Site]
    let selectedKey: String
    /// 按钮上的名字（没有可用站点时由上层给「选择站点」）。
    let title: String
    /// 显示名 / 搜索要的自定义名（``DiscoverSiteRuleInput`` 里菜单要用的只剩这一项）。
    var ruleInput = DiscoverSiteRuleInput()
    /// 已抽好的分组标签（`site key → 标签`）。
    ///
    /// 抽标签要跑正则，由上层在「输入变了 / 站点清单变了」时算好传进来
    /// （`HomeView.refreshSiteTags()`）—— **菜单内容的 `body` 何时求值由系统决定**，
    /// 不适合放这类计算；这里只做廉价的筛选与排序。
    var tags: [String: [String]] = [:]
    /// 存下来的分组顺序（空 = 用「按站点顺序首次出现」的默认顺序）。
    var savedGroupOrder: [String] = []
    /// 分组上移 / 下移（回传分组名与方向，由上层算新顺序并落盘）。
    var onMoveGroup: ((String, Int) -> Void)?
    /// 请求改名（菜单里放不下输入框：回传站点 key，由上层弹 `.alert`）。
    var onRenameRequest: ((String) -> Void)?
    /// 打开「查找站点」弹层（同上，菜单里放不下输入框）。
    var onFindRequest: (() -> Void)?
    let onSelect: (String) -> Void

    /// 当前筛的分组（空 = 不筛）。
    @State private var selectedGroup = ""

    private var groups: [String] {
        DiscoverSiteList.groups(sites: sites, tags: tags, savedOrder: savedGroupOrder)
    }

    private var rows: [DiscoverSiteRow] {
        DiscoverSiteList.rows(
            sites: sites,
            selectedKey: selectedKey,
            names: ruleInput.names,
            tags: tags,
            selectedGroup: selectedGroup
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

    /// 站点清单上面那一组：分组筛选 / 分组排序 / 查找 / 改名。
    ///
    /// 放在**清单前面**是有意的：站点一多，清单会把后面的项推得很深，而「查找站点」正是为长清单
    /// 准备的入口（分组筛选同理 —— 先筛出这一组，再在清单里挑）。
    @ViewBuilder
    private var tools: some View {
        if !groups.isEmpty {
            groupMenu
            if groups.count > 1, onMoveGroup != nil {
                sortMenu
            }
        }
        if let onFindRequest {
            Button {
                onFindRequest()
            } label: {
                Label("查找站点…", systemImage: "magnifyingglass")
            }
        }
        if let onRenameRequest {
            Menu("重命名站点") {
                ForEach(sites) { site in
                    Button(DiscoverSiteList.title(for: site, names: ruleInput.names)) {
                        onRenameRequest(site.key)
                    }
                }
            }
        }
    }

    /// 分组筛选：一个子菜单，当前项打勾（标题里带着当前筛的是哪一组 —— 菜单里没别处能显示它）。
    private var groupMenu: some View {
        Menu(selectedGroup.isEmpty ? "分组：全部" : "分组：\(selectedGroup)") {
            Button {
                selectedGroup = ""
            } label: {
                if selectedGroup.isEmpty {
                    Label("全部站点", systemImage: "checkmark")
                } else {
                    Text("全部站点")
                }
            }
            ForEach(groups, id: \.self) { group in
                Button {
                    selectedGroup = group
                } label: {
                    if group == selectedGroup {
                        Label(group, systemImage: "checkmark")
                    } else {
                        Text(group)
                    }
                }
            }
        }
    }

    /// 分组排序（M06g）：长按胶囊弹「上移 / 下移」的旧交互换成了菜单里的两级 ——
    /// 每个分组一个小节，两条动作。（横向滚动手势与拖动排序打架，上游那套长按拖动本来就没做。）
    private var sortMenu: some View {
        Menu("分组排序") {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    Button("上移") {
                        onMoveGroup?(group, -1)
                    }
                    Button("下移") {
                        onMoveGroup?(group, 1)
                    }
                }
            }
        }
    }

    /// 站点清单：一行一个站点，当前站点打勾（与「换线路」菜单同一个写法的对勾）。
    private var siteList: some View {
        Section {
            ForEach(rows) { row in
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
        } header: {
            Text(selectedGroup.isEmpty ? "站点" : "站点（\(selectedGroup)）")
        }
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
