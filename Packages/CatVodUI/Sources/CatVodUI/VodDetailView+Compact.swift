import CatVodCore
import CatVodSource
import SwiftUI

/// 精简视图（M26 对齐参考的 Normal 页）的成员：**上面一块播放器 + 下面详情**。
///
/// 为什么要拆：`VodDetailView` 的**类型体**又贴到 SwiftLint `type_body_length` 的 error 线（450 行）——
/// 与 `VodDetailView+TMDB.swift` / `+Data.swift` / `+Downloads.swift` 同一套做法（拆职责，不拆碎）。
/// 扩展不计入类型体；代价是这些成员**不能写 `private`**（private 是文件级，跨文件就看不见了）。
extension VodDetailView {
    /// 精简视图（M26 对齐参考的 Normal 页）：**上面一块播放器 + 下面详情** ——
    /// 片名 / 收藏 / 简介 / 「线路」胶囊 / 「剧集」胶囊列表；点一集**就地开播**，不推页面。
    var compactLayout: some View {
        // 量一次尺寸：顶上那块正常时按 16:9 定高（超屏就封顶），放大时铺满整屏
        // （见 `compactPlayer(width:availableHeight:expanded:)`）。
        GeometryReader { proxy in
            compactLayoutContent(size: proxy.size)
                // **放大只属于横屏**：页面尺寸一变就对着**接口方向**核一次（方向才是权威）——
                // 放大着的时候已经是竖屏了（用户自己转回来 / 系统转回来 / 转屏请求没成功），就收回去：
                // 不收的话留在竖屏上的是一张只剩播放器的空页 + 一整套完整控制条。
                // 刚放大那一下不算（`expandOrientationGraceSeconds`）：给转屏 / 尺寸回调留一段缓冲。
                .onChange(of: proxy.size) { size in
                    // 竖屏点的 ⤢ 在**容器真的横过来**这一刻落地（见 `expandInlinePlayback`）。
                    applyPendingInlineExpansion(width: size.width, height: size.height)
                    collapseIfPortraitWhileExpanded()
                }
        }
    }

    /// 精简视图那一版的内容（尺寸从外面的 `GeometryReader` 递进来）。
    ///
    /// 为什么拆成一个函数：`expanded` 要在 `return` 之前先算好（与 `playerControls(width:minimal:)`
    /// 同一写法 —— 函数体里先算局部量再 return 视图树）。
    func compactLayoutContent(size: CGSize) -> some View {
        // 这一帧按什么版式摆（判定在 `compactPlayerExpanded`，有单测）：
        // **竖屏点的 ⤢ 挂起中、容器刚横过来**的那一帧就直接按放大摆 —— 中间那版「横屏槽位」
        // 不会再被摆出来，画面区因此只上报一次尺寸（mpv 少重建一次视频输出，M28 首验之二十六）。
        let expanded = Self.compactPlayerExpanded(
            isExpanded: isInlineExpanded,
            pendingExpand: pendingInlineExpand,
            size: size
        )
        return VStack(spacing: 0) {
            // 播放器**钉在顶上**（与参考的「半屏播放器」同款）：它自己的拖动是调进度 / 音量 / 亮度，
            // 跟着滚会跟页面滚动抢手势 —— 分开两层，两边都干净。
            // 放大成全屏（`expanded`）时只留它：下面那块整体收掉，播放器自己铺满整屏。
            compactPlayer(width: size.width, availableHeight: size.height, expanded: expanded)
            if !expanded {
                // 列表滑动条藏起来（用户口径）：这块不是主列表，滚动条闪一下反而多余。
                // 横向边距从「整块 14」改成**各区自己带**：「线路」那条要全宽（见 `compactLineChips`）。
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        compactSynopsis
                            .padding(.horizontal, 14)
                        if lines.count > 1 {
                            compactLineChips
                        }
                        compactEpisodeSection
                            .padding(.horizontal, 14)
                        if !errorText.isEmpty {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 14)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
                .background(autoPlayLink)
            }
        }
    }

    /// 收回「就地放大」：只翻状态，**播放器一个字节都不动**（画面接着播）。
    /// 三处都走它 —— ✕、转回竖屏、转屏没成功，以后再加别的触发（别各写一份 `isInlineExpanded = false`）。
    func collapseInlineExpansion() {
        // 「竖屏点了 ⤢、还没等到横屏」的那种也一并取消（这次当没点着）。
        pendingInlineExpand = false
        expandStartedAt = nil
        expandCheckTask?.cancel()
        expandCheckTask = nil
        guard isInlineExpanded else {
            return
        }
        isInlineExpanded = false
    }

    /// 点开放大之后先别急着判方向（秒）：**放大自己会先把容器变成整屏竖屏**，
    /// 那一步不是「转回来了」；转屏请求也要几百毫秒才落地（M27 首验之六之五/之六的日志里都踩过）。
    static let expandOrientationGraceSeconds: TimeInterval = 1.2

    /// 放大着的时候**接口方向**已经是竖屏 → 把放大的收回（页面尺寸一变就核一次）。
    func collapseIfPortraitWhileExpanded() {
        guard isInlineExpanded else {
            return
        }
        guard let startedAt = expandStartedAt,
              Date().timeIntervalSince(startedAt) > Self.expandOrientationGraceSeconds
        else {
            return
        }
        guard PlatformShims.isPlaybackLandscape() == false else {
            return
        }
        collapseInlineExpansion()
    }

    /// 精简视图顶部那块播放器：**16:9 黑场**里挂 `PlaybackView`（只画面 + 叠层控制条）。
    ///
    /// 三种形态（见 ``compactPlayerContent``）：直链集就地播 → 站点换地址的集（type=3 / 4）也就地播
    /// （换地址在 `SitePlayEpisodeView` 里做，转圈与失败原因由它如实显示）→ 还没开播时摆海报 + 播放按钮。
    ///
    /// **尺寸由这块黑底说了算**（定尺 16:9），内容铺在它上面 —— 不能反过来（内容 + `.aspectRatio`）：
    /// `aspectRatio` 只是「提议」，子视图报多大就是多大 —— 转圈 / 文案这类**自带固有尺寸**的内容
    /// 会把槽位塌成一小块（M27 首验录屏里的「正在向站点请求播放地址…」小框就是这么来的）。
    ///
    /// 高度**自己算**（宽度 ÷ ``compactPlayerAspect`` = 16:9，再按 ``compactPlayerMaxHeightRatio`` 封顶），
    /// 别拿 `.aspectRatio(nil)` 表示
    /// 「放大时不定尺」—— 那个 `nil` 不是「不限比例」，而是按视图**自己的固有比例**走：
    /// `Color` 的固有比例是 1:1，于是放大后给出一块**方**槽位、两边露着页面白底（首验截图就是这个）。
    ///
    /// **放大成全屏**（M27 首验之四）：`expanded` 时高度不给（`nil` = 跟着父级铺满）
    /// 并忽略安全区 —— **同一块内容**（同一个 `PlaybackView`，引擎照旧在跑）跟着变大，
    /// 不重建播放器（重建要黑一下、还要重新拉流 / 重解析，用户看到的就是「旧状态又来了」）。
    ///
    /// `expanded` 由调用方算好递进来（``compactPlayerExpanded(isExpanded:pendingExpand:size:)``）：
    /// 它比 `isInlineExpanded` 早一帧为真 —— 转屏落地那一帧就直接按放大摆，不再先摆一版横屏槽位。
    func compactPlayer(width: CGFloat, availableHeight: CGFloat, expanded: Bool) -> some View {
        // 两个值都写明类型：三元塞进长表达式里会让类型检查器罢工（首验踩过
        // `failed to produce diagnostic`），显式一点最稳。
        let height: CGFloat? = expanded ? nil : Self.compactPlayerHeight(width: width, availableHeight: availableHeight)
        let regions: SafeAreaRegions = expanded ? .all : []
        return Color.black
            .frame(height: height)
            .overlay { compactPlayerContent(expanded: expanded) }
            .clipped()
            .ignoresSafeArea(regions, edges: .all)
    }

    /// 这一帧顶上那块按不按「放大」摆（**纯函数**，有单测）。
    ///
    /// 三种情况：真放大（`isExpanded`）；**竖屏点的 ⤢ 挂起中、容器已经横过来**（挂起落地的那一帧，
    /// 直接按放大摆 —— 中间那版「横屏槽位」不再被摆出来，画面区因此只上报一次尺寸，
    /// mpv 少重建一次 VO，M28 首验之二十六）；其余都不放大。
    static func compactPlayerExpanded(isExpanded: Bool, pendingExpand: Bool, size: CGSize) -> Bool {
        isExpanded || (pendingExpand && size.width > size.height)
    }

    /// 不放大时那块槽位的高度（**纯函数**，有单测）：16:9 定高，但**不超过可用高度的那一档**
    /// （``compactPlayerMaxHeightRatio``）—— 横屏下 874 宽按 16:9 算是 491，屏幕只有 402 高：
    /// 不封顶视频底会被裁（用户口径：精简视图横竖屏都要「适应屏幕」式完整显示，M28 首验之十八）。
    static func compactPlayerHeight(width: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(width / compactPlayerAspect, availableHeight * compactPlayerMaxHeightRatio)
    }

    /// 槽位里的内容（尺寸跟着上面的黑底走）。
    @ViewBuilder
    func compactPlayerContent(expanded: Bool) -> some View {
        if let target = inlinePlayback {
            inlinePlayer(for: target, expanded: expanded)
                .id(target.index)
        } else if let target = inlineSitePlayback {
            inlineSitePlayer(for: target, expanded: expanded)
                .id(target.index)
        } else {
            compactPlayerPlaceholder
        }
    }

    /// 站点换地址那种（type=3 CatSpider / type=4）：整块交给 ``SitePlayEpisodeView`` ——
    /// 它自己「换地址 → 直链就播 / 说要解析就转解析链 / 失败给原因」，我们只负责把它挂在顶上。
    @ViewBuilder
    func inlineSitePlayer(for target: PlaybackTarget, expanded: Bool) -> some View {
        if let site {
            SitePlayEpisodeView(
                model: model,
                site: site,
                episode: target.episode,
                title: vod?.vodName ?? "",
                lineName: currentLine?.name ?? "",
                episodeIndex: target.index,
                progressKey: progressKey,
                playlist: episodePlaylist(currentIndex: target.index),
                lineSwitcher: lineSwitcher(currentIndex: target.index),
                isFavorite: isFavorite,
                onToggleFavorite: { Task { await toggleFavorite() } },
                isFullScreen: true,
                onClose: { closeInlinePlayback { inlineSitePlayback = nil } },
                onRequestFullScreen: expandFullScreenAction,
                // 同上：这块也是定尺槽位（16:9），画面区不带下限；
                // 控制条走极简版（竖屏只摆徽标 / 进度 / 播放暂停 / 全屏，M27 首验之二）；
                // 放大成全屏后回到完整版（那边要 ✕ 才能收回来）。
                playerAreaMinHeight: 0,
                minimalControls: !expanded
            )
        }
    }

    /// 就地播放那块播放器：与推页那条**同一份参数**，多了「关掉这块画面」与「转全屏」两个回传。
    func inlinePlayer(for target: PlaybackTarget, expanded: Bool) -> some View {
        destination(
            for: target.episode,
            at: target.index,
            isFullScreen: true,
            onClose: { closeInlinePlayback { inlinePlayback = nil } },
            onRequestFullScreen: expandFullScreenAction,
            // 槽位尺寸由外面的 16:9 说了算：去掉画面区的 280 下限（不清掉会把槽位顶高，
            // 点播放的瞬间下面整页内容往下跳一截）；
            // 控制条走极简版（竖屏只摆徽标 / 进度 / 播放暂停 / 全屏，M27 首验之二）；
            // 放大成全屏后回到完整版（那边要 ✕ 才能收回来）。
            playerAreaMinHeight: 0,
            minimalControls: !expanded
        )
    }

    /// 还没开播时那块内容：站点海报铺底（黑场由槽位给）+ 中间一颗播放按钮
    /// （点了从「该播的那一集」开播）。
    var compactPlayerPlaceholder: some View {
        CachedImage(url: detail.artwork)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Color.black.opacity(0.25))
        .overlay(
            Image(systemName: "play.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.92))
        )
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            startInlinePlaybackFromSlot()
        }
    }

    /// 就地那块「放大成全屏」（M27 首验之四）：把状态一翻 —— **同一块画面**跟着铺满整屏，
    /// 播放器一个字节都不重建。翻横屏那颗在控制条上（`fullScreenButton` 里顺手做）。
    ///
    /// **竖屏时不当场放大，等容器真的横过来再放大（M28 首验之十三）**：同一帧里又重排整页、
    /// 又开转屏动画，转屏的头几帧要连着吃两次布局 + mpv 两次 VO 重建（竖屏整屏一次、横屏一次）——
    /// 用户报的「点全屏要卡一下」就是它。改成挂起（``pendingInlineExpand``）之后：布局只重排一次、
    /// mpv 只重建一次（`applyPendingInlineExpansion` 在尺寸回调里落地）。
    ///
    /// 落地那一帧的版式由 ``compactPlayerExpanded(isExpanded:pendingExpand:size:)`` 说了算：
    /// 挂起 + 容器已横过来时**直接按放大摆**，中间那版「横屏槽位」不摆出来（M28 首验之二十六；
    /// 那一版会多报一次画面区尺寸，mpv 就要多重建一次 VO —— 每次重建画面停一下）。
    ///
    /// 转屏这件事**不能一信到底**：`requestGeometryUpdate` 偶尔会被系统拒（首验日志里 15:54:34
    /// 那一次就是：放大 14 毫秒后被收回、窗口还留在竖屏）。所以这里起一个校验（见下）。
    func expandInlinePlayback() {
        guard PlatformShims.isPlaybackLandscape() != false else {
            // 竖屏：转屏请求已经在按钮里送出 —— 先挂起，等容器真的横过来再放大（见上）。
            pendingInlineExpand = true
            expandStartedAt = Date()
            scheduleExpandOrientationCheck()
            return
        }
        // 已经是横屏（或者拿不到方向）：直接把状态翻过去。
        applyInlineExpansion()
    }

    /// 竖屏点的 ⤢ 在**容器真的横过来**那一刻落地（`compactLayout` 的尺寸回调里调）。
    func applyPendingInlineExpansion(width: CGFloat, height: CGFloat) {
        guard pendingInlineExpand, width > height else {
            return
        }
        applyInlineExpansion()
    }

    /// 真放大：同一块画面铺满整屏 —— 地址 / 内核 / 进度一个都不动，只翻状态。
    func applyInlineExpansion() {
        pendingInlineExpand = false
        isInlineExpanded = true
        expandStartedAt = Date()
    }

    /// 放大之后校验转屏：0.9 秒还没横过来就**再求一次**；又来 0.9 秒还是竖屏就收回去 ——
    /// 宁可当这次 ⤢ 没点着，也不留一张「竖屏上只剩播放器」的空页（用户报过）。
    func scheduleExpandOrientationCheck() {
        expandCheckTask?.cancel()
        expandCheckTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled,
                  isInlineExpanded || pendingInlineExpand,
                  PlatformShims.isPlaybackLandscape() == false
            else {
                return
            }
            PlatformShims.requestPlaybackOrientation(landscape: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled,
                  isInlineExpanded || pendingInlineExpand,
                  PlatformShims.isPlaybackLandscape() == false
            else {
                return
            }
            // 两次都没转过去：这次 ⤢ 当没点着 —— 挂起的取消、已放大的收回。
            collapseInlineExpansion()
        }
    }

    /// 「转全屏」的回传：**已经放大（就是全屏）时给 nil** —— 控制条那颗 ⤢ 也就不出现（不摆没用的开关）。
    ///
    /// 为什么单拉一个显式类型的计算属性：`isInlineExpanded ? nil : expandInlinePlayback` 这种
    /// 「三元 + 方法引用」塞进 `PlaybackView` / `SitePlayEpisodeView` 的超长参数表，会把类型检查器
    /// 逼到 `failed to produce diagnostic for expression`（Mac 首验就是这么红的）。
    var expandFullScreenAction: (() -> Void)? {
        guard !isInlineExpanded else {
            return nil
        }
        return expandInlinePlayback
    }

    /// ✕ 的两种意思（M27 首验之四）：放大状态下 = 收回那块（**接着播** + 翻回竖屏）；
    /// 没放大时 = 清掉这块画面（`clear` 由两条路各自给：直链清 `inlinePlayback`、站点清 `inlineSitePlayback`）。
    func closeInlinePlayback(clear: @escaping () -> Void) {
        if isInlineExpanded {
            collapseInlineExpansion()
            PlatformShims.requestPlaybackOrientation(landscape: false)
        } else {
            clear()
        }
    }

    /// 播放器那块画面的比例：16:9（与参考那张「视频在上、详情在下」一致）。
    static let compactPlayerAspect: CGFloat = 16.0 / 9.0
    /// 横屏（或任何算出来比屏幕还高的容器）下，槽位最多占可用高度的这么多：留出下面那截
    /// （简介 / 线路 / 剧集）—— 纯 `min(16:9, 可用高)` 会把下面挤成 0（M28 首验之十八）。
    static let compactPlayerMaxHeightRatio: CGFloat = 0.62

    /// 从「该播的那一集」（有观看记录就是那一集）就地开播。
    ///
    /// 不能就地播的（要过解析链 / 不支持）**交回导航链** —— 与点剧集胶囊同一套口径：
    /// 那两条自带页面与网嗅，不是换一个地址能说完的。
    func startInlinePlaybackFromSlot() {
        guard let slot = playSlot else {
            return
        }
        guard canPlayInline(at: slot.index) else {
            openEpisode(at: slot.index)
            return
        }
        startInlinePlayback(at: slot.index)
    }

    /// 点一集就地播：直链走 ``inlinePlayback``，站点换地址的（type=3 / 4）走 ``inlineSitePlayback``。
    ///
    /// **调用方先问过 ``canPlayInline(at:)``**（不就地播的那两条走导航链，别把状态设歪）。
    func startInlinePlayback(at index: Int) {
        guard episodes.indices.contains(index) else {
            return
        }
        let target = PlaybackTarget(index: index, episode: episodes[index])
        if makeResource(for: episodes[index]) != nil {
            inlineSitePlayback = nil
            inlinePlayback = target
        } else {
            inlinePlayback = nil
            inlineSitePlayback = target
        }
    }

    /// 能不能**就地播**：直链，或 type=3 / type=4 那种「站点换地址」的。
    /// 要过解析链（自带页面与网嗅）与不支持的仍走推页 —— 那两条路不是「换一个地址」能说完的。
    func canPlayInline(at index: Int) -> Bool {
        let episode = episodes[index]
        if makeResource(for: episode) != nil {
            return true
        }
        guard let site else {
            return false
        }
        return isSpiderPlayable(site) || requiresSitePlay(site, episode: episode)
    }

    /// 简介：站点的 `vodContent`，默认三行（参考图就是三行 + 省略）。
    @ViewBuilder
    var compactSynopsis: some View {
        if let text = vod?.vodContent, !text.isEmpty {
            Text(text)
                .font(.footnote)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 「线路」胶囊组：选中那颗主题色填充（参考图同款；原来那排系统分段控件换成胶囊）。
    ///
    /// **横向滑动范围顶到屏幕左右边缘（用户口径）**：标题照旧缩进 14，ScrollView **不套页面边距** ——
    /// 从屏幕最边上就能起手滑、划到头也不被边距截住；内容自己带 14 的左右内边距（首尾与别区对得齐）。
    var compactLineChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.headline)
                .padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            selectedLineIndex = index
                        } label: {
                            Text(line.name)
                                .font(.subheadline)
                                .foregroundStyle(index == selectedLineIndex ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(chipBackground(selected: index == selectedLineIndex), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
            }
        }
    }

    /// 「剧集」区：标题 + 右侧两颗图标（展开文件名 / 正序倒序）+ 胶囊列表（当前集主题色）。
    var compactEpisodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 22) {
                Text("剧集")
                    .font(.headline)
                Spacer(minLength: 0)
                Button {
                    isEpisodeListExpanded.toggle()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEpisodeListExpanded ? "收起文件名" : "展开文件名")
                Button {
                    isEpisodeListDescending.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEpisodeListDescending ? "改成正序" : "改成倒序")
            }
            if episodes.isEmpty {
                Text(isLoading ? "加载中…" : "没有可用线路")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(orderedEpisodeIndices, id: \.self) { index in
                compactEpisodeChip(index)
            }
            wholeLineDownloadsRow
        }
    }

    /// 「剧集」列表当前显示的顺序（倒序开关只影响显示，不动数据）。
    var orderedEpisodeIndices: [Int] {
        let indices = Array(episodes.indices)
        return isEpisodeListDescending ? Array(indices.reversed()) : indices
    }

    /// 一颗剧集胶囊：**点了就地开播**（直链与站点换地址的都算）；要过解析链 / 不支持的照旧推页。
    @ViewBuilder
    func compactEpisodeChip(_ index: Int) -> some View {
        if canPlayInline(at: index) {
            Button {
                startInlinePlayback(at: index)
            } label: {
                compactEpisodeChipLabel(index)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                destination(for: episodes[index], at: index)
            } label: {
                compactEpisodeChipLabel(index)
            }
            .buttonStyle(.plain)
        }
    }

    /// 胶囊里的内容：文件名（默认一行，可展开）+ 不可播标记；当前集白字。
    func compactEpisodeChipLabel(_ index: Int) -> some View {
        let episode = episodes[index]
        let selected = playSlot?.index == index
        return HStack(spacing: 6) {
            Text(episode.name.isEmpty ? "第 \(index + 1) 集" : episode.name)
                .font(.footnote)
                .lineLimit(isEpisodeListExpanded ? nil : 1)
            if showsUnsupportedBadge(for: episode) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white : Color.orange)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(chipBackground(selected: selected), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 胶囊底色：选中 = 主题色，未选中 = 一层浅灰（参考图的线路 / 剧集胶囊同款）。
    func chipBackground(selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(PlatformShims.accent) : AnyShapeStyle(Color.primary.opacity(0.08))
    }
}
