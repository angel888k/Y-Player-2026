import CatVodCore
import CatVodSource
import Foundation

// 字幕的界面接线（M09c）：把播放结果里的 `subs` 接进播放流程。
//
// 与 `AppModel+Danmaku.swift` 同一套取舍：
// - **不抛错**：字幕是锦上添花，失败只该影响播放页那一行状态，不该把播放流程带崩；
// - **空结果不提示**：站点没给字幕是常态，不是错误（`SubtitleStatus.empty` 也只是如实说明）；
// - 传输复用 `transportForConfiguration()`，与站点请求同一套 header / 代理 / 广告拦截。
//
// 上屏见 `SubtitleOverlay`（M09f）：cue 排成时间轴（`SubtitleTimeline`），
// 再按播放时间逐帧画到视频底部 —— 与弹幕同一套骨架，共用同一个 `PlaybackClock`。

public extension AppModel {
    /// 载入一集的字幕。
    func loadSubtitles(_ request: SubtitleRequest) async {
        guard !request.isEmpty else {
            clearSubtitles()
            return
        }
        subtitleStatus = .loading
        subtitleCues = []
        let service = SubtitleService(transport: transportForConfiguration())
        do {
            guard let loaded = try await service.load(from: request.sources, headers: request.headers) else {
                subtitleStatus = .empty
                return
            }
            subtitleCues = loaded.cues
            subtitleStatus = loaded.cues.isEmpty
                ? .empty
                : .loaded(source: loaded.source.displayName, count: loaded.cues.count)
        } catch {
            subtitleStatus = .failed(reason: userFacingMessage(error))
        }
    }

    /// **起播前别等字幕**（M28P10）：清掉上一集那份（同步，免得串集），下载丢后台。
    ///
    /// 为什么要它：`loadSubtitles` 是网络活（按站点给的 `subs` 去下字幕文件）。原先三处调用点
    /// 都是 `await model.loadSubtitles(...)` 挡在「构造播放资源」前面 —— 用户报的
    /// 「播放视频前的加载速度有点慢」有一截就是它（字幕没下回来，播放页就不建）。
    /// 播放页观察的是 `model.subtitleCues`，下回来那份自己会上屏（没下回来就先不显示字幕）。
    ///
    /// - Parameters:
    ///   - sources: 站点给的候选字幕源（空数组 = 这一集没字幕，只做清空）。
    ///   - headers: 取字幕要带的 header。
    func loadSubtitlesInBackground(sources: [SubtitleSource], headers: [String: String]) {
        clearSubtitles()
        guard !sources.isEmpty else {
            return
        }
        Task { [weak self] in
            await self?.loadSubtitles(SubtitleRequest(sources: sources, headers: headers))
        }
    }

    /// 清掉字幕状态与已载入的 cue（换集 / 退出播放时用）。
    func clearSubtitles() {
        subtitleCues = []
        subtitleStatus = .idle
    }
}
