import CatVodCore
@testable import CatVodUI
import Foundation
import Testing

/// 详情页「TMDB 视图」的剧集网格列数（对齐参考的 Emby 视图：剧照卡基准 210×118、卡间距 6）。
///
/// 为什么把它单拎出来测：列数错一眼看不出来（手机上「一排一张」和「一排两张」是两种观感），
/// 而它只是个宽度 → 列数的纯换算，钉住口径最便宜。
@MainActor
@Suite("详情页剧集网格列数")
struct DetailEpisodeGridTests {
    @Test("手机宽度：2 列（320pt / 390pt 两种屏都算过）")
    func phoneWidthGivesTwoColumns() {
        #expect(VodDetailView.episodeGridColumnCount(forWidth: 362) == 2)
        #expect(VodDetailView.episodeGridColumnCount(forWidth: 292) == 2)
    }

    @Test("iPad 宽度：4~5 列（上夹到 5）")
    func padWidthGivesFourOrFiveColumns() {
        #expect(VodDetailView.episodeGridColumnCount(forWidth: 996) == 4)
        #expect(VodDetailView.episodeGridColumnCount(forWidth: 1338) == 5)
    }

    @Test("还没量到宽度（0）：先按 2 列（量到后下一帧换过来）")
    func unknownWidthFallsBackToTwo() {
        #expect(VodDetailView.episodeGridColumnCount(forWidth: 0) == 2)
    }
}
