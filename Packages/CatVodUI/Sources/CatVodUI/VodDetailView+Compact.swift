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
        VStack(spacing: 0) {
            // 播放器**钉在顶上**（与参考的「半屏播放器」同款）：它自己的拖动是调进度 / 音量 / 亮度，
            // 跟着滚会跟页面滚动抢手势 —— 分开两层，两边都干净。
            compactPlayer
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    compactSynopsis
                    if lines.count > 1 {
                        compactLineChips
                    }
                    compactEpisodeSection
                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .background(autoPlayLink)
        }
    }

    /// 精简视图顶部那块播放器：**16:9 黑场**里挂 `PlaybackView`（只画面 + 叠层控制条）。
    ///
    /// 三种形态（见 ``compactPlayerContent``）：直链集就地播 → 站点换地址的集（type=3 / 4）也就地播
    /// （换地址在 `SitePlayEpisodeView` 里做，转圈与失败原因由它如实显示）→ 还没开播时摆海报 + 播放按钮。
    ///
    /// **尺寸由这块黑底说了算**（定尺 16:9），内容铺在它上面 —— 不能反过来（内容 + `.aspectRatio`）：
    /// `aspectRatio` 只是「提议」，子视图报多大就是多大 —— 转圈 / 文案这类**自带固有尺寸**的内容
    /// 会把槽位塌成一小块（M27 首验录屏里的「正在向站点请求播放地址…」小框就是这么来的）。
    var compactPlayer: some View {
        Color.black
            .aspectRatio(Self.compactPlayerAspect, contentMode: .fit)
            .overlay { compactPlayerContent }
            .clipped()
    }

    /// 槽位里的内容（尺寸跟着上面的黑底走）。
    @ViewBuilder
    var compactPlayerContent: some View {
        if let target = inlinePlayback {
            inlinePlayer(for: target)
                .id(target.index)
        } else if let target = inlineSitePlayback {
            inlineSitePlayer(for: target)
                .id(target.index)
        } else {
            compactPlayerPlaceholder
        }
    }

    /// 站点换地址那种（type=3 CatSpider / type=4）：整块交给 ``SitePlayEpisodeView`` ——
    /// 它自己「换地址 → 直链就播 / 说要解析就转解析链 / 失败给原因」，我们只负责把它挂在顶上。
    @ViewBuilder
    func inlineSitePlayer(for target: PlaybackTarget) -> some View {
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
                onClose: { inlineSitePlayback = nil },
                onRequestFullScreen: {
                    inlineSitePlayback = nil
                    fullScreenPlayback = target
                },
                // 同上：这块也是定尺槽位（16:9），画面区不带下限；
                // 控制条走极简版（竖屏只摆徽标 / 进度 / 播放暂停 / 全屏，M27 首验之二）。
                playerAreaMinHeight: 0,
                minimalControls: true
            )
        }
    }

    /// 就地播放那块播放器：与推页那条**同一份参数**，多了「关掉这块画面」与「转全屏」两个回传。
    func inlinePlayer(for target: PlaybackTarget) -> some View {
        destination(
            for: target.episode,
            at: target.index,
            isFullScreen: true,
            onClose: { inlinePlayback = nil },
            onRequestFullScreen: {
                inlinePlayback = nil
                fullScreenPlayback = target
            },
            // 槽位尺寸由外面的 16:9 说了算：去掉画面区的 280 下限（不清掉会把槽位顶高，
            // 点播放的瞬间下面整页内容往下跳一截）；
            // 控制条走极简版（竖屏只摆徽标 / 进度 / 播放暂停 / 全屏，M27 首验之二）。
            playerAreaMinHeight: 0,
            minimalControls: true
        )
    }

    /// 还没开播时那块内容：站点海报铺底（黑场由槽位给）+ 中间一颗播放按钮
    /// （点了从「该播的那一集」开播）。
    var compactPlayerPlaceholder: some View {
        AsyncImage(url: URL(string: detail.artwork)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
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

    /// 播放器那块画面的比例：16:9（与参考那张「视频在上、详情在下」一致）。
    static let compactPlayerAspect: CGFloat = 16.0 / 9.0

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
    var compactLineChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路")
                .font(.headline)
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
