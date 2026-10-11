import SwiftUI

/// 选集面板（M28 首验之三十 · 自绘，用户口径）：**从右缘滑入**的剧集列表 ——
/// 视频照播（左边还看得见），面板占右侧约三分之一宽，当前集蓝底高亮。
///
/// 为什么自绘（《UI 规范》的破例，已获用户明确许可）：系统 sheet 只能从底部起、按高度档位停，
/// 做不出「右侧竖条面板」这个形态；而参考效果（VLC 式右侧面板）就是用户要的产品设计。
/// 与「播放器控制条」同一族例外（规范总则一的例外说明），只用在播放页的选集上。
/// 面板内部的控件仍全部是系统件（`ScrollView` / `Button` / 工具条）。
///
/// 版式（对齐参考截图）：
/// - 面板宽度 = 可用宽的 ``EpisodePanelGeometry/widthFraction``（夹在 min/max 之间，见 ``EpisodePanelGeometry``）；
/// - 左侧留一条**遮罩**（点它关面板）；面板从右缘滑入；
/// - 当前集：蓝底白字（参考图里那一条，在 ``EpisodeListDrawer`` 的行里）。
struct EpisodePanel<Content: View>: View {
    /// 是否展开（`false` 时整层不在视图树上；`true` 插入时走滑入过渡）。
    let isPresented: Bool
    /// 关面板（点遮罩 / 选完一集）。
    let onClose: () -> Void
    /// 面板内容（播放页给的就是 ``EpisodeListDrawer`` —— 行与排序逻辑不重写）。
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { proxy in
                    let width = EpisodePanelGeometry.width(availableWidth: proxy.size.width)
                    HStack(spacing: 0) {
                        Color.black.opacity(0.28)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onClose)
                        content()
                            .frame(width: width)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: isPresented)
    }
}

/// 选集面板的纯几何（有单测）。**顶层枚举而不是泛型里的嵌套**：泛型类型里不能有 static 存储属性。
enum EpisodePanelGeometry {
    /// 参考口径：占屏幕宽的三分之一。
    static let widthFraction: CGFloat = 1.0 / 3.0
    /// 太窄面板放不下集名（竖屏 iPhone 上按 1/3 只有 ~130pt）。
    static let minWidth: CGFloat = 260
    /// 太宽就不像「面板」了（iPad 横屏 1/3 接近 400pt）。
    static let maxWidth: CGFloat = 420

    /// 面板宽：可用宽 × 1/3，夹在 [minWidth, maxWidth]。
    /// 竖屏（可用宽 ≈ 402）按 1/3 只有 134pt、放不下集名 —— 就靠 minWidth 撑住。
    static func width(availableWidth: CGFloat) -> CGFloat {
        let base = availableWidth * widthFraction
        return min(max(base, minWidth), maxWidth)
    }
}
