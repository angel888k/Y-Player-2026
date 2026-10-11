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
        #expect(height == 402 / (16.0 / 9.0))
    }

    @Test("横屏：封顶在可用高度的 0.62 —— 视频完整、下面那截留得住")
    func landscape() {
        let height = VodDetailView.compactPlayerHeight(width: 874, availableHeight: 402)
        #expect(height == 402 * VodDetailView.compactPlayerMaxHeightRatio)
        #expect(height < 874 / (16.0 / 9.0))
        #expect(height < 402)
    }
}
