import CoreGraphics
import SwiftUI
import Testing
@testable import CatVodUI

/// 选集面板的几何（M28 首验之三十）：面板宽 = 可用宽的三分之一，夹在 [min, max]。
/// 纯函数有单测，视图只照它画。
@Suite("选集面板：几何")
struct EpisodePanelTests {
    @Test("横屏（可用宽 874）：取三分之一（291pt）")
    func landscapeThird() {
        let width = EpisodePanel<EmptyView>.Geometry.width(availableWidth: 874)
        #expect(abs(width - 874 / 3) < 0.01)
    }

    @Test("竖屏（可用宽 402）：三分之一只有 134pt，抬到下限 260")
    func portraitClampsToMinimum() {
        let width = EpisodePanel<EmptyView>.Geometry.width(availableWidth: 402)
        #expect(width == EpisodePanel<EmptyView>.Geometry.minWidth)
    }

    @Test("超宽（iPad 横屏 1366）：三分之一 455pt，压到上限 420")
    func padClampsToMaximum() {
        let width = EpisodePanel<EmptyView>.Geometry.width(availableWidth: 1366)
        #expect(width == EpisodePanel<EmptyView>.Geometry.maxWidth)
    }

    @Test("参考截图那台（可用宽 874 横屏）落在 [min, max] 之间，不等于边界")
    func referenceDeviceInRange() {
        let width = EpisodePanel<EmptyView>.Geometry.width(availableWidth: 874)
        #expect(width > EpisodePanel<EmptyView>.Geometry.minWidth)
        #expect(width < EpisodePanel<EmptyView>.Geometry.maxWidth)
    }
}
