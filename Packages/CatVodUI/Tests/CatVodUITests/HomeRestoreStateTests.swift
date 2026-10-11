import Testing
@testable import CatVodUI

/// 冷启动恢复中的判定（M28 首验之三十一）：发现页在「保存过接口、还没加载完」的窗口里
/// 显示「站点加载中…」，其余情况不能盖住原有文案。
@Suite("发现页：冷启动恢复态")
@MainActor
struct HomeRestoreStateTests {
    @Test("保存过接口 + 站点还空 + 还没开始加载 → 恢复中（显示「站点加载中…」）")
    func restoring() {
        #expect(HomeView.isRestoringSavedSource(
            configURL: "https://example.com/config.json",
            stateIsIdle: true,
            sitesIsEmpty: true
        ))
    }

    @Test("没保存过接口 → 不是恢复中（走原来的空态提示）")
    func noSavedSource() {
        #expect(!HomeView.isRestoringSavedSource(
            configURL: "",
            stateIsIdle: true,
            sitesIsEmpty: true
        ))
        #expect(!HomeView.isRestoringSavedSource(
            configURL: "   ",
            stateIsIdle: true,
            sitesIsEmpty: true
        ))
    }

    @Test("已经在加载 / 已加载 / 已失败 → 不是恢复中（各自走自己的文案）")
    func afterIdle() {
        #expect(!HomeView.isRestoringSavedSource(
            configURL: "https://example.com/config.json",
            stateIsIdle: false,
            sitesIsEmpty: true
        ))
    }

    @Test("站点已经出来了 → 不是恢复中（哪怕状态还是 idle）")
    func sitesLoaded() {
        #expect(!HomeView.isRestoringSavedSource(
            configURL: "https://example.com/config.json",
            stateIsIdle: true,
            sitesIsEmpty: false
        ))
    }
}
