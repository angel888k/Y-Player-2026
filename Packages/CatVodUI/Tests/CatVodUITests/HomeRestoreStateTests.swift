import CatVodCore
import CatVodSource
@testable import CatVodUI
import Testing

/// 冷启动恢复中的判定（M28 首验之三十一）：发现页在「保存过接口、站点清单还没出来」的窗口里
/// 显示「站点加载中…」，其余情况不能盖住原有文案。
@Suite("发现页：冷启动恢复态")
struct HomeRestoreStateTests {
    private func isRestoring(
        configURL: String = "https://example.com/config.json",
        state: AppModel.LoadState = .idle,
        hostIsBusy: Bool = false,
        sitesIsEmpty: Bool = true
    ) -> Bool {
        AppModel.isRestoringSavedSource(
            configURL: configURL,
            state: state,
            hostIsBusy: hostIsBusy,
            sitesIsEmpty: sitesIsEmpty
        )
    }

    @Test("配置还没加载完（idle / loading）→ 恢复中")
    func beforeLoaded() {
        #expect(isRestoring(state: .idle))
        #expect(isRestoring(state: .loading))
    }

    /// 已加载的配置（测试替身：空 JSON 配置就够 —— 判定只看 `state` 的形状与宿主忙不忙）。
    private var loadedState: AppModel.LoadState {
        .loaded(LoadedSource(kind: .json, config: SourceConfig()))
    }

    @Test("配置已加载、JS 宿主正在起步 → 仍是恢复中（这一段最长，冷启动看到的就是它）")
    func hostStarting() {
        #expect(isRestoring(state: loadedState, hostIsBusy: true))
    }

    @Test("宿主已起完、站点清单真的为空 → 不是恢复中（走各自的说明文案）")
    func hostIdleWithEmptySites() {
        #expect(!isRestoring(state: loadedState, hostIsBusy: false))
    }

    @Test("加载失败 → 不是恢复中（显示失败原因，不能被「加载中」盖住）")
    func failedShowsReason() {
        #expect(!isRestoring(state: .failed("炸了")))
    }

    @Test("没保存过接口 → 不是恢复中（走原来的空态提示）")
    func noSavedSource() {
        #expect(!isRestoring(configURL: ""))
        #expect(!isRestoring(configURL: "   "))
    }

    @Test("站点已经出来了 → 不是恢复中")
    func sitesLoaded() {
        #expect(!isRestoring(sitesIsEmpty: false))
    }
}
