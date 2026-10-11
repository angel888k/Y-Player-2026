import CatVodCore
import CatVodSource
import CatVodStore
import SwiftUI

/// TMDB 视图（M11）的成员：加载骨架、大播放按钮、图标行、版式、选集横滑与剧集列表抽屉的入口。
///
/// （视图当时按参考的 Emby 客户端排布起名叫「Emby 视图」，后来改名 TMDB 视图 —— 名字变了，
/// 排布没变。）
///
/// 拆出来的原因很实在：`VodDetailView` 的**类型体**超过 SwiftLint `type_body_length`
/// 的 error 线（450 行）。扩展不计入类型体 —— 与仓库既有的 `VodDetailView+Data.swift`
/// 是同一个做法。
///
/// 这些成员因此**不能写 `private`**（private 是文件级，跨文件就看不见了）。
/// 它们访问的 `detail` / `episodes` / `progress` / `model` 等本来就是 internal；
/// 反向依赖（`wholeLineDownloadsRow` / `autoPlayLink` / `progressSummary` /
/// `isLastWatched(_:)` / `destination(for:at:)`）随本次拆分从 private 放宽到 internal，
/// 主文件里各自带一行说明。
extension VodDetailView {
    /// 全幅骨架加载态（M11）：和真布局**同一副骨架** —— 大图 + 标题行 + 播放条 + 一排卡片。
    ///
    /// 参考视频里加载中就是这个形状，不是一个居中转圈。所以第一次进页面时，
    /// 屏幕上先出现「就是这里将来会有东西」的灰块，内容回来时原地换成真东西、不跳版。
    var tmdbSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            skeletonBlock(width: nil, height: 320)
            skeletonBlock(width: 140, height: 18)
            skeletonBlock(width: 96, height: 14)
            // 播放条
            skeletonBlock(width: nil, height: 44)
            // 选集：两列 16:9 占位，形状跟真卡片（剧照 + 文件名）对齐
            HStack(alignment: .top, spacing: 6) {
                skeletonBlock(width: nil, height: 96)
                skeletonBlock(width: nil, height: 96)
            }
        }
    }

    /// 灰块：`width: nil` 表示占满可用宽度。
    func skeletonBlock(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: PlatformShims.cardCornerRadius)
            .fill(Color.secondary.opacity(0.15))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    /// 图标行（M11 参考图：🔍 聚合搜索 / ♡ 收藏 / ⋯ 更多）。
    ///
    /// 🔍 的落点是 ``AggregateSearchView``（M11 片 5）：按片名并发搜各站点、按站点分组的海报墙。
    /// ♡ 与 ⋯ 各自接真实动作。
    var iconRow: some View {
        HStack(spacing: 64) {
            NavigationLink {
                AggregateSearchView(model: model, keyword: vod?.vodName ?? "")
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Menu {
                Toggle("元信息刮削", isOn: $model.tmdbScrapeEnabled)
                Button("手动匹配元信息…") {
                    isShowingMetadataMatch = true
                }
                Text(model.isTMDBConfigured ? "TMDB 已配置" : "TMDB 未配置（设置 → 播放 → 播放页）")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 该播哪一集：**有观看记录就是那一集**（=「继续播放」），否则第一集。
    var playSlot: (index: Int, episode: PlaylistParser.Episode)? {
        guard let first = episodes.first else {
            return nil
        }
        let index = progress?.episodeIndex ?? 0
        guard episodes.indices.contains(index) else {
            return (0, first)
        }
        return (index, episodes[index])
    }

    /// 大播放按钮（M11）：参考视频里它是**上行动作 + 下行信息**两行。
    ///
    /// 下行用的是站点给的集名 —— 视频里那一行 `[1.4GB]157.mp4 【X 仙逆】 · 01:51`
    /// 就是「文件名（自带体积）+ 上次进度」，两个数据站点都已经给了，不用另造。
    @ViewBuilder
    var playButtonRow: some View {
        if let slot = playSlot {
            // 「点播放直接全屏」（M26）：不再先落竖屏播放页，直接进全屏那层（画面 + 叠层控制条）。
            Button {
                fullScreenPlayback = PlaybackTarget(index: slot.index, episode: slot.episode)
            } label: {
                VStack(spacing: 8) {
                    // 大按钮：**浅底深字**（`Color.primary` 的低透明度当底、主色当字）—— 浅色外观下
                    // 就是参考图里那块浅色按钮，深色外观自动翻成深底白字（不写死颜色）。
                    Label(actionTitle, systemImage: "play.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    if !subtitle(of: slot.episode).isEmpty {
                        Text(subtitle(of: slot.episode))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 「继续播放」还是「播放」：**有进度且没看完**才叫继续。
    var actionTitle: String {
        guard let progress, progress.position > 0, !progress.isFinished else {
            return "播放"
        }
        return "继续播放"
    }

    func subtitle(of episode: PlaylistParser.Episode) -> String {
        var parts = [episode.displayName]
        if let progress, progress.position > 0, !progress.isFinished {
            parts.append(Self.timeText(Int(progress.position)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `01:51` / `1:02:03`。自己拼不用 `String(format:)`，省一个 Foundation 依赖。
    static func timeText(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hour = total / 3600
        let minute = (total % 3600) / 60
        let second = total % 60
        func pad(_ value: Int) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return hour > 0
            ? "\(hour):\(pad(minute)):\(pad(second))"
            : "\(pad(minute)):\(pad(second))"
    }

    // MARK: - TMDB 视图

    /// TMDB 视图（设置 → 播放 → 播放页 → 显示视图）：**全幅沉浸版** ——
    /// 海报铺满顶部、渐变压暗，标题与线路名叠在图上；下面依次是播放按钮、图标行、简介与选集。
    ///
    /// 数据与精简视图完全相同（`detail` / `lines` / `episodes` / `progress`），
    /// 只是排布不同 —— 收藏、换源、续播的行为一致。
    var tmdbLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading, detail.list.isEmpty {
                    // 第一次进页面才给骨架；内容回来后原地换掉。
                    tmdbSkeleton
                        .padding(16)
                } else {
                    TMDBDetailHeader(
                        model: model,
                        title: vod?.vodName ?? "",
                        fallbackPoster: detail.artwork,
                        lineName: currentLine?.name ?? "",
                        mode: model.tmdbPosterMode
                    )
                    VStack(spacing: 18) {
                        playButtonRow
                        iconRow
                        tmdbOverview
                        tmdbEpisodeHeader
                        tmdbEpisodeGrid
                        wholeLineDownloadsRow
                        if !errorText.isEmpty {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
        }
        // 外观跟随应用 / 系统：浅色时页面就是系统底（用户口径：深色模式跟随系统，不强制）。
        // 只有头图上的叠字保持白色 —— 它压在图与黑色渐变上，两套外观下都该是白的。
        .background(autoPlayLink)
        // 页面级拉取：取图集 + 元信息（顶部与卡片共用同一次刮削；键变了才重拉）。
        .task(id: episodePosterLoadKey) {
            await loadEpisodePosterSet()
        }
        .sheet(isPresented: $isEpisodeDrawerPresented) {
            EpisodeListDrawer(
                episodes: episodes,
                currentIndex: playSlot?.index
            ) { index in
                openEpisode(at: index)
            }
            // 参考图里抽屉只占半屏（上面的详情还看得见）；iOS 15 没有半屏形态，回落整页。
            .adaptiveHalfSheet()
        }
        .sheet(isPresented: $isShowingMetadataMatch) {
            TMDBMatchSheet(model: model, title: vod?.vodName ?? "") { key in
                // 落库在 model 上；两个 `.task(id:)` 的加载键都含匹配 token，会各自重拉。
                model.setTMDBMatchKey(key, for: vod?.vodName ?? "")
            }
            .adaptiveHalfSheet()
        }
    }

    /// 简介（参考图里图标行下面那段）：TMDB overview 优先，没刮到回落到站点的 vodContent。
    ///
    /// 默认只露两行、**点一下展开 / 收起**（对齐参考的 Emby 视图 `_synopsisExpanded`）；
    /// 原先「影片」分区里那些说明字段（备注 / 类型 / 年份 / 进度文案）不再单列 ——
    /// 标题、线路名、简介已各就各位；进度在播放按钮下面那行里。
    @ViewBuilder
    var tmdbOverview: some View {
        let overview = episodeMetadata?.overview ?? ""
        let text = overview.isEmpty ? (vod?.vodContent ?? "") : overview
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(isSynopsisExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsSynopsisToggle {
                    Text(isSynopsisExpanded ? "收起" : "展开")
                        .font(.caption2)
                        .foregroundStyle(PlatformShims.accent)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSynopsisExpanded.toggle()
                }
            }
            .accessibilityHint("点一下展开或收起简介")
        }
    }

    /// 简介要不要给「展开 / 收起」：**够短就别摆**（两行放得下的文案，点了也不会有变化）。
    ///
    /// 判定按字数粗筛、不按排版量（真量要拿到渲染宽度，代价不值）：参考页里简介都是一整段，
    /// 超两行是常态；这里用「超过 40 字」当门槛，短简介不摆多余那一行。
    var showsSynopsisToggle: Bool {
        let overview = episodeMetadata?.overview ?? ""
        let text = overview.isEmpty ? (vod?.vodContent ?? "") : overview
        return text.count > 40
    }

    /// 选集区头（参考图）：「线路名 ▾」（点开切线路）+ 上一集 / 下一集 + 更多（剧集列表抽屉）。
    ///
    /// 原先单独一个「线路」胶囊区，按参考图收进这里 —— 一屏只留一处线路入口。
    var tmdbEpisodeHeader: some View {
        HStack(spacing: 18) {
            Menu {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Button {
                        selectedLineIndex = index
                    } label: {
                        Text(index == selectedLineIndex ? "✓ \(line.name)" : line.name)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentLine?.name ?? "线路")
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }

            Spacer(minLength: 0)

            Button {
                if let index = previousEpisodeIndex {
                    openEpisode(at: index)
                }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(previousEpisodeIndex == nil)
            .opacity(previousEpisodeIndex == nil ? 0.35 : 1)

            Button {
                if let index = nextEpisodeIndex {
                    openEpisode(at: index)
                }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(nextEpisodeIndex == nil)
            .opacity(nextEpisodeIndex == nil ? 0.35 : 1)

            Button {
                isEpisodeDrawerPresented = true
            } label: {
                Text("更多")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 选集网格（对齐参考的 Emby 视图）：16:9 剧照、圆角 14、卡间距 6，列数按可用宽度算。
    ///
    /// 列数口径来自参考实现字面池的判读（剧照卡基准 210×118、卡间距 6、页面内边距 14）：
    /// `columns = clamp(⌊(W + 6) / (210 + 6)⌋, 2, 5)` —— 手机 2 列、iPad 4~5 列。
    @ViewBuilder
    var tmdbEpisodeGrid: some View {
        if episodes.isEmpty {
            if isLoading {
                HStack(alignment: .top, spacing: 6) {
                    skeletonBlock(width: nil, height: 96)
                    skeletonBlock(width: nil, height: 96)
                }
            } else {
                Text("没有可用线路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: episodeGridColumns, spacing: 14) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    Button {
                        fullScreenPlayback = PlaybackTarget(index: index, episode: episode)
                    } label: {
                        tmdbEpisodeCard(episode, at: index)
                    }
                    .buttonStyle(.plain)
                }
            }
            // 量一次可用宽度算列数：宽变（转屏 / iPad 分栏）跟着重算。
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { episodeGridWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { width in
                            episodeGridWidth = width
                        }
                }
            )
        }
    }

    /// 网格列数（量到的可用宽度；还没量到时先按 2 列，量到后下一帧就换过来）。
    var episodeGridColumns: [GridItem] {
        let count = Self.episodeGridColumnCount(forWidth: episodeGridWidth)
        return Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: count)
    }

    /// 列数：卡宽下限 210 + 间距 6，夹在 2...5（口径见参考字面池的判读）。
    static func episodeGridColumnCount(forWidth width: CGFloat) -> Int {
        guard width > 0 else {
            return 2
        }
        return min(max(Int((width + 6) / 216), 2), 5)
    }

    /// 剧集剧照：16:9（参考实现的卡基准 210×118 就是 16:9），圆角 14（同参考字面池）。
    static let episodeStillAspectRatio: CGFloat = 16.0 / 9.0
    static let episodeStillCornerRadius: CGFloat = 14

    /// 这张卡片该显示的图：`step` 用下标、`seed` 加下标打散 —— 各卡片各取一张、每次进来一样
    /// （取图规则见 ``PosterPicker``；这里不另立一套）。
    ///
    /// 没有 TMDB 取图集（未配 / 没搜到 / 刮削关）时回落**站点海报** ——
    /// 参考图里每张卡片也是这张海报；总比一排纯文字卡像样。
    func episodePosterURL(at index: Int) -> URL? {
        if let picked = episodePosterSet?.image(step: index, seed: episodePosterSeed &+ UInt64(index)) {
            return URL(string: picked)
        }
        let fallback = detail.artwork
        return fallback.isEmpty ? nil : URL(string: fallback)
    }

    /// 单张选集卡片（对齐参考的 Emby 视图）：16:9 剧照 + 文件名，图下面不要卡片底。
    ///
    /// 没有取图集时（未配 key / 没搜到 / 刮削关）退化成纯文字卡 —— 不给「永远灰着」的图块。
    func tmdbEpisodeCard(_ episode: PlaylistParser.Episode, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imageURL = episodePosterURL(at: index) {
                Color.clear
                    .aspectRatio(Self.episodeStillAspectRatio, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: imageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.clear
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Self.episodeStillCornerRadius))
            }
            HStack(alignment: .top, spacing: 4) {
                Text(episode.name.isEmpty ? "第 \(index + 1) 集" : episode.name)
                    .font(.caption2)
                    .lineLimit(4)
                if showsUnsupportedBadge(for: episode) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            if isLastWatched(index) {
                Text("上次看到")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 卡片取图集的加载键：片名 / 取图模式变了才重拉（缓存与合流在 `AppModel` 那层）。
    var episodePosterLoadKey: String {
        let title = vod?.vodName ?? ""
        // 手动匹配也进键（M11 片 5）：在「⋯」里选了新的一条，这里就该重拉。
        return "\(title)|\(model.tmdbPosterMode.rawValue)|\(model.tmdbMatchToken(for: title))"
    }

    /// 拉页面要用的取图集 + 元信息：与顶部走同一份（同键并发会合流，不会各拉一次）。
    /// 简介那一行（``tmdbOverview``）用的就是这里的 metadata。
    func loadEpisodePosterSet() async {
        let title = vod?.vodName ?? ""
        guard !title.isEmpty else {
            return
        }
        let outcome = await model.tmdbBundle(for: title, mode: model.tmdbPosterMode)
        if case let .found(bundle) = outcome {
            episodePosterSet = bundle.posterSet
            episodeMetadata = bundle.metadata
        }
    }

    /// 点一集开播（抽屉里选中的、区头的上一集 / 下一集都走它）：
    /// 关抽屉 → 走与点卡片**同一条**隐藏导航链进播放页。
    ///
    /// 先等一小会儿再激活：抽屉退场动画没走完就 push，返回时偶发一层空白
    /// （与 `scheduleAutoPlayIfNeeded` 延迟 0.3 秒是同一个理由）。
    func openEpisode(at index: Int) {
        guard episodes.indices.contains(index) else {
            return
        }
        isEpisodeDrawerPresented = false
        autoPlayEpisodeIndex = index
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            isAutoPlaying = true
        }
    }

    /// 「上一集」：以「该播的那一集」为基准（与播放按钮同一集）；到头回 nil。
    var previousEpisodeIndex: Int? {
        guard let base = playSlot?.index, base > 0 else {
            return nil
        }
        return base - 1
    }

    /// 「下一集」：同上（末集回 nil）。
    var nextEpisodeIndex: Int? {
        guard let base = playSlot?.index, episodes.indices.contains(base + 1) else {
            return nil
        }
        return base + 1
    }
}

/// 全屏播放的落点（M26）：集 + 下标（`fullScreenCover(item:)` 要 `Identifiable`）。
struct PlaybackTarget: Identifiable {
    let index: Int
    let episode: PlaylistParser.Episode

    var id: Int { index }
}
