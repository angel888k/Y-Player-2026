import SwiftUI

// 选集面板的接线（M28 首验之三十）：从右缘滑入、视频照播、面板占右约 1/3 宽。
// 单拆一个文件：`PlaybackView` 的类型体贴着 SwiftLint `type_body_length` 的 error 线（450），
// 与 `PlaybackView+*` 其它扩展同一套做法。

extension PlaybackView {
    /// 选集面板的整层（遮罩 + 右缘面板）。没有播放列表时整层不存在（面板无从谈起）。
    @ViewBuilder
    var episodePanelOverlay: some View {
        if let playlist {
            EpisodePanel(isPresented: isEpisodeDrawerPresented) {
                isEpisodeDrawerPresented = false
            } content: {
                EpisodeListDrawer(
                    episodes: playlist.episodes,
                    currentIndex: currentEpisodeIndex,
                    highlight: .accent
                ) { index in
                    isEpisodeDrawerPresented = false
                    Task { await switchEpisode(to: index) }
                }
            }
        }
    }
}
