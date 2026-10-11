import CatVodCore
import SwiftUI

/// 剧集列表抽屉（M11 · 选集区头「更多」的落点）：整屏文件列表、当前集高亮、可滚动 ——
/// 以半屏 sheet 叠加在详情页 / 播放页上。
///
/// 行还是参考的「更多」弹层那样：一行一个**胶囊**，当前集底色更亮。**抽屉这条头归系统**
/// （M28 首验之二十五）：标题走 `navigationTitle`、右上两个开关（展开 / 收起、正序 / 倒序）
/// 走工具栏 —— 原先那条自绘头（`HStack` + 标题 + 图标按钮）就是「自绘导航栏」，
/// 与 `docs/UI 规范.md` 总则一冲突（同一个头在 iOS 15 / iOS 16+ / macOS 上长得一模一样）。
///
/// 刻意保持「纯展示 + 一个回调」：数据与跳转都在 `VodDetailView` —— 点一集回传下标，
/// 由那边关抽屉并走**与点卡片同一条**的隐藏导航链进播放页（不另开一条跳转路径）。
struct EpisodeListDrawer: View {
    /// 当前集的高亮风格：抽屉形态沿用「底色更亮」（详情页那处）；右缘面板照参考图用**蓝底白字**。
    enum Highlight {
        /// 灰底更亮（原样，详情页的抽屉用）。
        case subtle
        /// 蓝底白字（参考图；播放页的右缘面板用）。
        case accent
    }

    let episodes: [PlaylistParser.Episode]
    /// 当前集下标（「继续播放 / 上次看到」那一集）；nil = 不高亮。
    let currentIndex: Int?
    /// 点一集：回传下标，由调用方负责关抽屉与跳转。
    let onSelect: (Int) -> Void
    /// 当前集高亮风格（默认原样；见 ``Highlight``）。
    var highlight: Highlight = .subtle

    /// 正序 / 倒序：只影响抽屉里的显示顺序，不动数据。
    @State private var descending = false
    /// 行里文件名是否展开成多行（长文件名默认一行，展开后看全）。
    @State private var expanded = false

    var body: some View {
        AdaptiveNavigationContainer {
            // 胶囊行自己是完整的「一行」：用 `ScrollView + LazyVStack` 而不是 `List` ——
            // 行间距 / 行底色全由这里定，也免得用上 macOS 没有的 list row 修饰符。
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(orderedIndices, id: \.self) { index in
                        row(at: index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("剧集列表")
            .adaptiveInlineNavigationTitle()
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                headerButtons
            }
        }
    }

    private var orderedIndices: [Int] {
        let indices = Array(episodes.indices)
        return descending ? Array(indices.reversed()) : indices
    }

    /// 右上两个开关（展开 / 收起文件名、正序 / 倒序）：走**工具栏**（原生位置），
    /// 不再自绘一条头（M28 首验之二十五）。两个都只是**开关**，动作与原来一模一样。
    private var headerButtons: some View {
        HStack(spacing: 16) {
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.body)
            }
            .accessibilityLabel(expanded ? "收起文件名" : "展开文件名")
            Button {
                descending.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.body)
            }
            .accessibilityLabel(descending ? "改成正序" : "改成倒序")
        }
    }

    /// 一行：文件名（空名回落「第 N 集」）—— 胶囊底，**当前集高亮**（风格见 ``Highlight``，
    /// 参考图里是蓝底白字）。
    ///
    /// 行是 `Button` 但走 `.plain` 样式：默认样式会把没显式定色的文字全刷成 tint 蓝
    /// （播放器设置页刚栽过一次），这里的颜色配比是刻意的。
    private func row(at index: Int) -> some View {
        let isCurrent = index == currentIndex
        return Button {
            onSelect(index)
        } label: {
            Text(episodes[index].name.isEmpty ? "第 \(index + 1) 集" : episodes[index].name)
                .font(.footnote)
                .foregroundStyle(isCurrent ? currentTextColor : Color.primary)
                .lineLimit(expanded ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    isCurrent ? currentBackground : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
    }

    /// 当前集底色（`accent` = 系统蓝；`subtle` = 原样的「更亮一层」）。
    private var currentBackground: Color {
        switch highlight {
        case .subtle: Color.primary.opacity(0.16)
        case .accent: Color.accentColor
        }
    }

    /// 当前集文字色（`accent` 下是白字）。
    private var currentTextColor: Color {
        switch highlight {
        case .subtle: .primary
        case .accent: .white
        }
    }
}
