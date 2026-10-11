import CatVodCore
import SwiftUI

/// 剧集列表抽屉（M11 · 选集区头「更多」的落点）：整屏文件列表、当前集高亮、可滚动 ——
/// 以半屏 sheet 叠加在详情页上。
///
/// 排布对齐参考的「更多」弹层：标题「剧集列表」+ 右上两个图标按钮（展开 / 收起、正序 / 倒序），
/// 一行一个**胶囊**（当前集底色更亮）。
///
/// 刻意保持「纯展示 + 一个回调」：数据与跳转都在 `VodDetailView` —— 点一集回传下标，
/// 由那边关抽屉并走**与点卡片同一条**的隐藏导航链进播放页（不另开一条跳转路径）。
struct EpisodeListDrawer: View {
    let episodes: [PlaylistParser.Episode]
    /// 当前集下标（「继续播放 / 上次看到」那一集）；nil = 不高亮。
    let currentIndex: Int?
    /// 点一集：回传下标，由调用方负责关抽屉与跳转。
    let onSelect: (Int) -> Void

    /// 正序 / 倒序：只影响抽屉里的显示顺序，不动数据。
    @State private var descending = false
    /// 行里文件名是否展开成多行（长文件名默认一行，展开后看全）。
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(orderedIndices, id: \.self) { index in
                    row(at: index)
                }
            }
            .listStyle(.plain)
        }
    }

    private var orderedIndices: [Int] {
        let indices = Array(episodes.indices)
        return descending ? Array(indices.reversed()) : indices
    }

    /// 抽屉头：标题 + 右上两个图标按钮（展开 / 收起、正序 / 倒序）—— 形状照参考的「更多」弹层。
    private var header: some View {
        HStack(spacing: 22) {
            Text("剧集列表")
                .font(.headline)
            Spacer()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 一行：文件名（空名回落「第 N 集」）—— 胶囊底，**当前集底色更亮**（对齐参考的「更多」弹层）。
    ///
    /// 行是 `Button` 但走 `.plain` 样式：默认样式会把没显式定色的文字全刷成 tint 蓝
    /// （播放器设置页刚栽过一次），这里的颜色配比是刻意的。
    private func row(at index: Int) -> some View {
        Button {
            onSelect(index)
        } label: {
            Text(episodes[index].name.isEmpty ? "第 \(index + 1) 集" : episodes[index].name)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    index == currentIndex ? Color.primary.opacity(0.16) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
    }
}
