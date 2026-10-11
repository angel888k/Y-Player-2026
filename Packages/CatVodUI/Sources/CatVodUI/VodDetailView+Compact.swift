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
                    compactTitleRow
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
    @ViewBuilder
    var compactPlayer: some View {
        if let target = inlinePlayback {
            inlinePlayer(for: target)
                .aspectRatio(Self.compactPlayerAspect, contentMode: .fit)
                .background(Color.black)
        } else {
            compactPlayerPlaceholder
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
            }
        )
    }

    /// 还没开播时那块画面：站点海报铺底（黑场）+ 中间一颗播放按钮（点了从「该播的那一集」开播）。
    var compactPlayerPlaceholder: some View {
        Color.black
            .aspectRatio(Self.compactPlayerAspect, contentMode: .fit)
            .overlay(
                AsyncImage(url: URL(string: detail.artwork)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            )
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

    /// 从「该播的那一集」（有观看记录就是那一集）就地开播；直链不了的那几种仍走推页（点剧集胶囊）。
    func startInlinePlaybackFromSlot() {
        guard let slot = playSlot, makeResource(for: slot.episode) != nil else {
            return
        }
        inlinePlayback = PlaybackTarget(index: slot.index, episode: slot.episode)
    }

    /// 片名 + 收藏（参考图里就是片名右边一颗星）。
    var compactTitleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(vod?.vodName.isEmpty == false ? (vod?.vodName ?? "") : "详情")
                .font(.title3.bold())
            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.body)
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(progressKey == nil)
            .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
            Spacer(minLength: 0)
        }
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

    /// 一颗剧集胶囊：直链集**点了就地开播**；换地址 / 解析 / 不支持的那几种照旧推页。
    @ViewBuilder
    func compactEpisodeChip(_ index: Int) -> some View {
        if makeResource(for: episodes[index]) != nil {
            Button {
                inlinePlayback = PlaybackTarget(index: index, episode: episodes[index])
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
