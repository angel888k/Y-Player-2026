import CatVodCore
import CatVodSource
import CatVodStore
import SwiftUI

/// 详情页：影片信息 → 线路 → 选集 → 播放。
///
/// 播放能力边界：
/// - 直链且无需解析的集（`parse = 0`）可直接用系统播放器播放；
/// - js2p / CatSpider HTTP 站点（`type=3` 且 `api` 含 `/spider/`）与 `type=4` 站点走 ``SitePlayEpisodeView``：
///   先用 `POST /play` 换取地址（需要宿主就绪，见 `docs/任务记录/M16P3-macOS宿主接通.md`）；
/// - 需要解析的集（`parse/jx = 1`）依赖 M5 的解析链；JAR / Python Spider 在 Apple 平台不支持。
/// 以上不可播放的情况都会进入 ``UnsupportedPlaybackView`` 并说明原因，不静默失败。
@MainActor
public struct VodDetailView: View {
    @ObservedObject var model: AppModel
    /// 当前站点/条目：**换源会就地替换**，因此是 `@State` 而不是 `let`。
    @State var site: Site?
    @State var vodID: String

    @State var detail = SpiderResult()
    @State var lines: [PlaylistParser.Line] = []
    @State var selectedLineIndex = 0
    @State var isLoading = false
    @State var errorText = ""
    @State private var isShowingChangeSource = false
    /// 本片进度：`+Data.swift` 里的 `loadProgress()` / `switchSource(to:)` 也要读写，因此**不能是 private**。
    @State var progress: PlaybackProgress?
    /// 是否已收藏：`+Data.swift` 里的 `loadFavorite()` / `toggleFavorite()` 读写，因此不能是 private。
    @State var isFavorite = false
    /// 自动播放待进入的集下标（`nil` = 不触发）；由 `+Data.swift` 在详情加载完成后写入。
    @State var autoPlayEpisodeIndex: Int?
    /// 隐藏导航链的激活开关（`NavigationLink(isActive:)`，iOS 15 / macOS 13 都支持）。
    ///
    /// 由 `+Data.swift` 的 `scheduleAutoPlayIfNeeded()` 打开，因此**不能是 private**
    /// （`private` 只对声明所在文件开放）。
    @State var isAutoPlaying = false

    /// 选集卡片取图的随机种子：进页面定一次（`.random` 模式下卡片用它 + 下标打散，见 ``PosterPicker``）。
    @State var episodePosterSeed = UInt64.random(in: 0 ..< UInt64.max)
    /// 选集卡片共用的取图集（与顶部同一次刮削，经 `AppModel.tmdbBundle(for:mode:)` 缓存与合流）。
    @State var episodePosterSet: TMDBPosterSet?
    /// 同一次刮削的元信息（简介那一行要用；没刮到时为 nil）。
    @State var episodeMetadata: TMDBMetadata?
    /// 剧集列表抽屉是否展开（M11：选集区头的「更多」；回传的跳转走 `openEpisode(at:)`）。
    @State var isEpisodeDrawerPresented = false
    /// 「⋯」→ 手动匹配元信息（M11 片 5）的面板是否打开。
    @State var isShowingMetadataMatch = false
    /// 简介是否展开（对齐参考的 Emby 视图：默认 2 行，点一下展开 / 收起）。
    @State var isSynopsisExpanded = false
    /// 选集网格量到的可用宽度（算列数用；见 `VodDetailView+TMDB.swift` 的 `episodeGridColumnCount`）。
    @State var episodeGridWidth: CGFloat = 0
    /// TMDB 视图下点播放 / 点剧集卡要进的那一集：**走全屏**（参考口径「emby 视图下点击播放直接全屏」）。
    @State var fullScreenPlayback: PlaybackTarget?
    /// 精简视图顶部那块**就地播放**的落点（参考的 Normal 页：视频在上、详情在下）；nil = 还没开播。
    /// 直链集走这个；type=3 / type=4 那种「站点换地址」的走 ``inlineSitePlayback``。
    @State var inlinePlayback: PlaybackTarget?
    /// 同样挂在顶上、但要先向站点 / 宿主换地址的那种（`SitePlayEpisodeView` 自己换）。
    @State var inlineSitePlayback: PlaybackTarget?
    /// 就地那块**放大成全屏**了没有（M27 首验之四）：true = 只留画面铺满整屏（导航栏也藏），
    /// 顺手翻横屏 —— **同一块画面放大**，不重建播放器（重建 = 黑一下 + 重新拉流 / 重解析）。
    /// 控制条右下角那颗 ⤢ 进、✕ 出（出 = 收回那块，接着播）。
    @State var isInlineExpanded = false
    /// 精简视图「剧集」列表的两个开关（对齐参考图右侧那两颗图标：展开文件名 / 正序倒序）。
    @State var isEpisodeListExpanded = false
    @State var isEpisodeListDescending = false
    /// 「整部下载（逐集换地址）」是否正在跑：按钮据此置灰，避免点两遍并行换地址。
    @State var isResolvingDownloads = false
    /// 上面那件事的进度 / 结果文案（换地址串行做，一格一格更新）。
    @State var resolvingDownloadsText = ""

    public init(model: AppModel, site: Site?, vodID: String) {
        self.model = model
        _site = State(initialValue: site)
        _vodID = State(initialValue: vodID)
    }

    var vod: VodItem? {
        detail.list.first
    }

    /// 进度记录键（站点 + vodID）；缺站点时为 nil（不记录）。
    var progressKey: PlaybackKey? {
        guard let site else {
            return nil
        }
        return PlaybackKey(siteKey: site.key, vodID: vodID)
    }

    var currentLine: PlaylistParser.Line? {
        guard lines.indices.contains(selectedLineIndex) else {
            return lines.first
        }
        return lines[selectedLineIndex]
    }

    var episodes: [PlaylistParser.Episode] {
        currentLine?.episodes ?? []
    }

    // 下载入口那一簇（`directDownloadEpisodes` / `siteDownloadEpisodes` / `wholeLineDownloadsRow`）
    // 已拆到 `VodDetailView+Downloads.swift`（类型体余量，见该文件说明）。

    // TMDB 视图的成员已拆到 VodDetailView+TMDB.swift（类型体超过 SwiftLint 上限，见该文件说明）。

    public var body: some View {
        content
            .navigationTitle(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "详情") : "详情")
            // 详情页是沉浸页：登记给本 Tab 的根页面，由它把底部 Tab 栏收起来（见 Platform/AdaptiveTabBar.swift）。
            .immersiveTabBarPage()
            // 就地放大那块（M27 首验之四）：导航栏（返回 / 收藏 / 换源）一起藏，画面铺满整屏。
            .adaptiveNavigationBarHidden(isInlineExpanded)
            // 全屏播放那一层（M26）：两种视图共用 —— 精简视图的就地播放器点 ⤢ 也走它。
            // 走基础件：iOS 是 `fullScreenCover`，macOS 没有这个形态、回落系统 sheet。
            .adaptiveFullScreenCover(item: $fullScreenPlayback) { target in
                fullScreenDestination(for: target)
            }
            .refreshable {
                await loadDetail(force: true)
                await loadProgress()
            }
            .adaptiveToolbar {
                Button {
                    Task { await toggleFavorite() }
                } label: {
                    Label(isFavorite ? "已收藏" : "收藏", systemImage: isFavorite ? "heart.fill" : "heart")
                }
                .disabled(progressKey == nil)
            } trailing: {
                Button {
                    isShowingChangeSource = true
                } label: {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.sites.count < 2)
            }
            .sheet(isPresented: $isShowingChangeSource) {
                ChangeSourceView(
                    model: model,
                    title: vod?.vodName ?? "",
                    currentSiteKey: site?.key,
                    onPick: { candidate in
                        switchSource(to: candidate)
                    }
                )
            }
            .task {
                await loadDetail()
                await loadProgress()
                await loadFavorite()
                // 自动播放（设置 → 播放 → 播放页）放在进度之后：有观看记录时以「上次看到」为准，
                // 不把用户从上次的位置拽回第一集。
                scheduleAutoPlayIfNeeded()
            }
            .onAppear {
                // 从播放页返回时刷新「上次看到这里」标记与收藏状态。
                Task {
                    await loadProgress()
                    await loadFavorite()
                }
            }
    }

    /// 按「显示视图」（设置 → 播放 → 播放页 → 显示视图）选排布。
    ///
    /// 两种视图**共用同一份数据与同一套工具**（收藏 / 换源 / 续播 / 自动播放），只换排布，
    /// 所以切换视图不会丢任何状态。
    @ViewBuilder
    private var content: some View {
        switch model.playbackPageLayout {
        case .compact:
            compactLayout
        case .tmdb:
            tmdbLayout
        }
    }

    /// 全屏那一层的落点（M26）：直链集直接全屏播放；其余（站点换地址 / 解析 / 不支持）包一层
    /// 导航容器 —— 那几张页面自带工具栏与返回按钮，卸掉导航会把人困住。
    @ViewBuilder
    func fullScreenDestination(for target: PlaybackTarget) -> some View {
        if makeResource(for: target.episode) != nil {
            destination(for: target.episode, at: target.index, isFullScreen: true)
        } else {
            // 换地址 / 解析那几张页面自带工具栏与返回：包一层**版本自适应**的导航容器
            // （iOS 16+/macOS 是 NavigationStack，iOS 15 是 NavigationView + .stack）。
            AdaptiveNavigationContainer {
                destination(for: target.episode, at: target.index)
            }
        }
    }

    /// 自动播放用的隐藏导航链（设置 → 播放 → 播放页 → 自动播放）。
    ///
    /// 用 `NavigationLink(isActive:)` 而不是 `navigationDestination`：后者要 iOS 16+，
    /// 而本项目下限是 iOS 15（`docs/UI 规范.md`：不为统一观感抬高下限）。
    /// 挂在 `background` 上而不是当作列表行：列表行会占掉一行高度，留一片空白。
    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+TMDB.swift` 也要用，不能是 private。）
    var autoPlayLink: some View {
        if let index = autoPlayEpisodeIndex, episodes.indices.contains(index) {
            NavigationLink(isActive: $isAutoPlaying) {
                // 自动播放跟着显示视图走（M26）：TMDB 视图本来就是「点播放直接全屏」。
                destination(for: episodes[index], at: index, isFullScreen: model.playbackPageLayout == .tmdb)
            } label: {
                EmptyView()
            }
        }
    }

    /// 是否为「上次看到」的那一集（**当前线路内**下标；跨线路/跨站对齐留 M8）。
    // （internal：拆分出的 `VodDetailView+TMDB.swift` 也要用，不能是 private。）
    func isLastWatched(_ index: Int) -> Bool {
        guard let progress, !progress.isFinished else {
            return false
        }
        return progress.episodeIndex == index && progress.position > 0
    }

    /// 播放页自己的换集能力（M12P1）：把「第 i 集怎么变成资源」包成闭包交给播放页
    /// —— 播放页不认识站点，换集的路子由详情页决定。
    ///
    /// 三种集走三条路（与 ``destination(for:at:)`` 的分派一一对应）：
    /// - 直链（type 0/1/2）：同步造资源；
    /// - 要向站点 / 宿主换地址（type 3/4）：异步换（与 `SitePlayEpisodeView` 同一条路）；
    /// - 需要解析链的集：返回 nil —— 那条路播放页不自己走，界面会提示回详情页点。
    func episodePlaylist(currentIndex: Int) -> PlaybackPlaylist {
        PlaybackPlaylist(
            episodes: episodes,
            currentIndex: currentIndex,
            loadResource: { index in
                guard episodes.indices.contains(index) else {
                    return nil
                }
                return await episodeResource(for: episodes[index], at: index)
            }
        )
    }

    /// 把某一集变成资源：直链（type 0/1/2）同步造；要向站点 / 宿主换地址的（type 3/4）异步换；
    /// 需要解析链的返回 nil（那条路播放页不自己走）。
    ///
    /// **换集与换线路（M03P17）共用这一条** —— 取地址的规则只有一份。
    func episodeResource(for episode: PlaylistParser.Episode, at index: Int) async -> PlaybackEpisodeResource? {
        let context = progressContext(for: episode, at: index)
        if let resource = makeResource(for: episode) {
            return PlaybackEpisodeResource(
                resource: resource,
                progressContext: context,
                title: episode.displayName
            )
        }
        guard let site, isSpiderPlayable(site) || requiresSitePlay(site, episode: episode) else {
            return nil
        }
        guard let resource = await siteResource(site: site, episode: episode) else {
            return nil
        }
        return PlaybackEpisodeResource(
            resource: resource,
            progressContext: context,
            title: episode.displayName
        )
    }

    /// 播放页自己的换线路能力（M03P17，对齐上游播放页的线路条）：线路清单 + 「另一条线路上的同一集怎么取」。
    ///
    /// 只有一条线路时不给（播放页据此不显示线路区）。
    /// 同一集的找法：**先按集名**（线路之间集数 / 顺序常常不一样），名字对不上再按下标兜底
    /// （规则在 `PlaybackLineSwitcher.matchIndex`，有单测）。
    func lineSwitcher(currentIndex: Int) -> PlaybackLineSwitcher? {
        guard lines.count > 1 else {
            return nil
        }
        return PlaybackLineSwitcher(
            lines: lines.map(\.name),
            current: currentLine?.name ?? "",
            load: { line, episodeName, index in
                guard let target = lines.first(where: { $0.name == line }),
                      let hit = PlaybackLineSwitcher.matchIndex(
                          episodeName: episodeName,
                          index: index,
                          names: target.episodes.map(\.name)
                      )
                else {
                    return nil
                }
                return await episodeResource(for: target.episodes[hit], at: hit)
            },
            onLineChanged: { line in
                // 详情页的线路选择跟着换：返回时停在刚看的那条线上。
                if let index = lines.firstIndex(where: { $0.name == line }) {
                    selectedLineIndex = index
                }
            }
        )
    }

    /// 播放页「下载本集」的交回口（M10h）：站内拿不到站点 key 时用详情页自己的站点兜底，
    /// 两个都空就是 `.unsupported`（`enqueueDownloadsAndStart` 会挡）。
    func enqueuePlaybackDownload(
        _ requests: [DownloadRequest],
        siteKey: String,
        title: String,
        headers: [String: String]
    ) async -> DownloadEnqueueOutcome {
        await model.enqueueDownloadsAndStart(
            requests,
            siteKey: siteKey.isEmpty ? (site?.key ?? "") : siteKey,
            title: title,
            headers: headers
        )
    }

    @ViewBuilder
    // （internal：拆分出的 `VodDetailView+TMDB.swift` 也要用，不能是 private。）
    func destination(
        for episode: PlaylistParser.Episode,
        at index: Int,
        isFullScreen: Bool = false,
        onClose: (() -> Void)? = nil,
        onRequestFullScreen: (() -> Void)? = nil,
        playerAreaMinHeight: CGFloat = 280,
        minimalControls: Bool = false
    ) -> some View {
        // 播放页自己的换集能力（M12P1）：详情页知道「集列表 + 线路 + 站点」，包成闭包交给它。
        let playlist = episodePlaylist(currentIndex: index)
        if let resource = makeResource(for: episode) {
            PlaybackView(
                resource: resource,
                title: episode.displayName,
                settings: model.playbackSettings,
                isFullScreen: isFullScreen,
                onClose: onClose,
                onRequestFullScreen: onRequestFullScreen,
                // 定尺槽位（精简视图顶上那块）传 0：别让画面区的下限把外面的 16:9 顶高。
                playerAreaMinHeight: playerAreaMinHeight,
                // 极简控制条：只有精简视图顶上那块的**竖屏**要（见 `PlaybackView/minimalControls`）。
                minimalControls: minimalControls,
                // 就地换了内核（M26）：记成默认，下次进来自动用新内核（与设置页那次选择同一条路）。
                onEngineChanged: { kind in
                    model.preferredEngine = kind
                },
                progressContext: progressContext(for: episode, at: index),
                progressStore: model.progressStore,
                // 直链路径（type 0/1/2 的 CMS 站）以前没有弹幕请求 —— M08c 只接了站点/解析两条路，
                // 于是这类站点永远搜不到弹幕（M03P18 补上；结果体里没有内嵌弹幕，所以不带 embedded）。
                danmaku: DanmakuRequest(name: vod?.vodName ?? "", episode: episode.displayName),
                onDanmaku: { request in Task { await model.loadDanmaku(request) } },
                subtitleDisplay: model.subtitleDisplay,
                subtitleCues: model.subtitleCues,
                danmakuLines: model.danmakuLines,
                danmakuDisplay: model.danmakuDisplay,
                onDanmakuDisplayChanged: { model.setDanmakuDisplay($0) },
                danmakuSwitcher: model.playbackDanmakuSwitcher,
                onEnqueueDownloads: { requests, siteKey, title, headers in
                    await enqueuePlaybackDownload(requests, siteKey: siteKey, title: title, headers: headers)
                },
                onPlaybackStats: { model.notePlaybackStats($0) },
                playlist: playlist,
                lineSwitcher: lineSwitcher(currentIndex: index),
                onStart: {
                    // 开播先把上一次的残留清掉（M03P18 / M03P22：这些都是全局的，不清会串到下一部片）
                    model.resetAdSkip()
                    model.clearDanmaku()
                    model.clearSubtitles()
                    model.clearPlaybackInfo()
                },
                playbackInfoRows: model.playbackInfoRows,
                isFavorite: isFavorite,
                onToggleFavorite: { Task { await toggleFavorite() } }
            )
        } else if let site, isSpiderPlayable(site) {
            // js2p / CatSpider 站点：播放地址要用 `POST /play` 换，因此走异步入口。
            SitePlayEpisodeView(
                model: model,
                site: site,
                episode: episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: index,
                progressKey: progressKey,
                playlist: playlist,
                lineSwitcher: lineSwitcher(currentIndex: index),
                isFavorite: isFavorite,
                onToggleFavorite: { Task { await toggleFavorite() } }
            )
        } else if let site, requiresSitePlay(site, episode: episode) {
            // type=4：播放地址要用站点的 `play` 接口换（`play` + `flag`），同样是异步入口（M06n）。
            SitePlayEpisodeView(
                model: model,
                site: site,
                episode: episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: index,
                progressKey: progressKey,
                playlist: playlist,
                lineSwitcher: lineSwitcher(currentIndex: index),
                isFavorite: isFavorite,
                onToggleFavorite: { Task { await toggleFavorite() } }
            )
        } else if let site, canParse(episode) {
            // 需要解析（`parse/jx = 1`）的集：走解析链（M5b 已支持 type=1 JSON；type=0/4 会给出 M5c 的原因）。
            ParsePlaybackView(
                model: model,
                site: site,
                vodName: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episode: episode,
                episodeIndex: index,
                detail: detail,
                progressKey: progressKey,
                isFavorite: isFavorite,
                onToggleFavorite: { Task { await toggleFavorite() } }
            )
        } else {
            UnsupportedPlaybackView(reason: unsupportedReason(for: episode))
        }
    }
}
