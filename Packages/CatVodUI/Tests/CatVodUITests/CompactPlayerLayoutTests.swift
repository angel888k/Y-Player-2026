@testable import CatVodUI
import Foundation
import Testing

/// 精简视图顶上那块播放器槽位的高度（M28 首验之十八）：16:9 定高，但**不超过可用高度的那一档** ——
/// 横屏下 874 宽按 16:9 算是 491，屏幕只有 402 高：不封顶视频底会被裁掉。
///
/// `@MainActor`：`VodDetailView` 是 `@MainActor` 的，它的静态成员也在主 actor 上。
@Suite("精简视图：播放器槽位高度")
@MainActor
struct CompactPlayerLayoutTests {
    @Test("竖屏：16:9 就够小，照旧不封顶")
    func portrait() {
        let height = VodDetailView.compactPlayerHeight(width: 402, availableHeight: 874)
        // 期望值直接写数：16:9 之下 = 402 × 9 ÷ 16 = 226.125（封顶那条路是 541.88，差着量级）。
        // 别写回 `402 / (16.0 / 9.0)` 那种纯字面量表达式：编译器折叠出来的值和运行时差最后一位 ——
        // 上机首跑就是这么挂的（两边显示一样、比较不过）。留 0.001pt 余量，不跟浮点末位较劲。
        #expect(abs(height - 226.125) < 0.001)
    }

    @Test("竖屏点的 ⤢：容器一横过来就直接按放大摆（中间那版横屏槽位不摆出来 —— 少一次尺寸上报）")
    func pendingExpansionLandsInOneStep() {
        // 挂起中 + 容器已经横过来：直接按放大摆（`applyPendingInlineExpansion` 在同一次回调里翻状态，
        // 版式不再变 —— 画面区因此只上报一次尺寸，mpv 少重建一次 VO）。
        #expect(VodDetailView.compactPlayerExpanded(
            isExpanded: false,
            pendingExpand: true,
            size: CGSize(width: 874, height: 402)
        ))
        // 挂起中 + 还是竖屏：照旧按槽位摆（不抢先铺满竖屏 —— M28 首验之十三 的口径）。
        #expect(!VodDetailView.compactPlayerExpanded(
            isExpanded: false,
            pendingExpand: true,
            size: CGSize(width: 402, height: 874)
        ))
        // 没挂起：只有真放大才算放大。
        #expect(!VodDetailView.compactPlayerExpanded(
            isExpanded: false,
            pendingExpand: false,
            size: CGSize(width: 874, height: 402)
        ))
        #expect(VodDetailView.compactPlayerExpanded(
            isExpanded: true,
            pendingExpand: false,
            size: CGSize(width: 402, height: 874)
        ))
    }

    @Test("横屏：封顶在可用高度的 0.62 —— 视频完整、下面那截留得住")
    func landscape() {
        let height = VodDetailView.compactPlayerHeight(width: 874, availableHeight: 402)
        #expect(height == 402 * VodDetailView.compactPlayerMaxHeightRatio)
        #expect(height < 874 / (16.0 / 9.0))
        #expect(height < 402)
    }
}
