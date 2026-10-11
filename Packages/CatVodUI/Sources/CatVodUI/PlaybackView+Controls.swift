import CatVodPlayer
import SwiftUI

/// 播放页的**叠层控制条**（M03P6 起；M26 按参考的全屏播放器重排；M27 起三个内核共用）。
///
/// 排布对齐参考截图（完整版）：
/// - 顶排：关闭（✕）· 投屏 · 旋转 · 画面比例 —— 右侧：画中画 · 弹幕 · 倍速 · 锁定；
/// - 底排：参数徽标（`HW HDR H265 4K 25FPS 5.6Mbps`，**只报读得到的**）+「当前时间 · 进度条 · 总时长」，
///   再一行：播放 / 暂停 · 下一集 · 逐帧 —— 右侧文字按钮「播放器 / 字幕 / 视轨 / 音轨 / 片头片尾 / 选集」。
///
/// **极简版**（M27 首验之二）：精简视图顶上那块在**竖屏**只摆参考里圈住的那几样 ——
/// 参数徽标 / 进度 / 播放暂停 / 右下角那颗「全屏」；其余按钮去全屏那层（那边**始终**是完整版）。
/// 横屏下那块槽位（宽度够）恢复完整版。
///
/// 参考里的**画质（滤镜）**我们不做，照「不摆假开关」的规矩不出现；**投屏**只有系统内核有公开 API
/// （`AVRoutePickerView`，M27 首验之三 —— DLNA 的结论见 M26 第七节）。各按钮自带能力判定：
/// 内核做不到的整颗不出现（画面比例 / 视轨 / 音频增益 / 画中画 / 投屏），拿不到的数据不占位（参数徽标）。
///
/// 为什么三个内核共用一条（M27）：系统内核的画面也换成了自建宿主（``SystemVideoView``，
/// 一层 `AVPlayerLayer`）—— `AVKit.VideoPlayer` 自带的那套控件与手势会跟这条打架；
/// 换掉之后，三个内核的按钮与手势才真的一致（见 `docs/任务记录/M27-*.md`）。
///
/// 锁屏（M03P21）也落在这一条上：锁上之后**常规内容整块藏起来，只剩锁按钮** —— 上游 `control.right.lock` 同款。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Speed` / `+Gestures` / `+OpeningEnding` / `+Lines` 同一套做法。
extension PlaybackView {
    /// 整条叠层：顶排图标 + 底排（锁上时只剩锁按钮）。
    ///
    /// `width`：画面区的可用宽度 —— 窄（竖屏 iPhone，< ``barCompactWidth``）时底排换**图标版**：
    /// 那排文字按钮（播放器 / 字幕 / 视轨 / 音轨 / 片头片尾 / 选集）在 390pt 放不下，
    /// 之前会被压成「播…」「…」（M27 首验录屏里就是它）—— 窄了换图标，动作与菜单内容一模一样。
    ///
    /// `minimal`：精简视图顶上那块传 true —— **竖屏**再收成极简版（徽标 / 进度 / 播放暂停 / 全屏，
    /// 参考里圈住的就是这几样）；横屏（宽度够）回到完整版。全屏那层永远不传 true。
    func playerControls(width: CGFloat, minimal: Bool = false) -> some View {
        let compact = width < Self.barCompactWidth
        let minimalBar = minimal && compact
        return VStack(spacing: 10) {
            if isLocked {
                HStack {
                    Spacer(minLength: 0)
                    lockButton
                }
            } else if minimalBar {
                Spacer(minLength: 0)
                bottomControls(compact: compact, minimal: true)
            } else {
                topIconRow(compact: compact)
                Spacer(minLength: 0)
                bottomControls(compact: compact, minimal: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(barBackdrop)
    }

    /// 上下两条压暗：只压边缘，不糊整屏（参考图里字直接压在画面上、不垫整块底）。
    ///
    /// 高度封顶 110 / 180（沉浸全屏的量），但**再按可用高度收**（``backdropGradientHeights(forHeight:)``）：
    /// 精简视图顶上那块 16:9 槽位只有 ~220pt，固定的两条加起来 290 会顶出画面 —— 底那条糊到下面的内容上。
    private var barBackdrop: some View {
        GeometryReader { proxy in
            let heights = Self.backdropGradientHeights(forHeight: proxy.size.height)
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: heights.top)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: heights.bottom)
            }
        }
        .allowsHitTesting(false)
    }

    /// 两条压暗的高度（**纯函数**，有单测）：封顶 110 / 180，再乘可用高度的 35% / 55%。
    ///
    /// 两个系数之和是 0.9 —— 任何高度下两条加起来都放得下（不顶出画面外）。
    static func backdropGradientHeights(forHeight height: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (min(110, height * 0.35), min(180, height * 0.55))
    }

    /// 控制条窄到放不下文字按钮的宽度线。
    ///
    /// 宽版底排要 ~541pt（3 颗图标 90 + 六颗文字按钮 225 + 九个间隔 198 + 内边距 28）——
    /// 横屏（~844）与 iPad 都在线上；竖屏 iPhone（390 / 402 / 375）在线下。
    static let barCompactWidth: CGFloat = 560
    /// 窄版的间距（10：9 颗 30pt 图标 + 8 个间隔 + 两侧内边距 ≈ 378pt，留得住 390 / 402）。
    static let barCompactSpacing: CGFloat = 10

    /// 顶排（M27 首验之三按参考图对齐）：关闭 · **投屏** · 旋转 · 画面比例 ——
    /// 画中画 · 弹幕 · 倍速 · 锁定。
    private func topIconRow(compact: Bool) -> some View {
        HStack(spacing: compact ? Self.barCompactSpacing : 24) {
            barIcon("xmark", label: "关闭播放") {
                closePlayback()
            }
            castButton
            rotateButton
            scaleMenu
            Spacer(minLength: 0)
            pipButton
            danmakuMenu
            speedMenu
            lockButton
        }
    }

    /// 底排：参数徽标 + 进度 + 动作行。
    private func bottomControls(compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !statBadges.isEmpty {
                badgesRow
            }
            progressRow
            transportRow(compact: compact, minimal: minimal)
        }
    }

    /// 参数徽标（参考图那排 `HW HDR H265 4K 25FPS 5.6Mbps`）。
    private var badgesRow: some View {
        HStack(spacing: 12) {
            ForEach(statBadges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    /// 进度那行：当前时间 · 滑杆 · 总时长。
    private var progressRow: some View {
        HStack(spacing: 10) {
            Text(Self.timeText(latestPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
            Slider(
                value: seekBinding,
                in: 0 ... max(latestDuration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    guard !editing else { return }
                    // 松手才 seek：一次拖动会产生几十个中间值，逐个 seek 会把内核打爆。
                    let target = latestPosition
                    Task { await engine?.seek(to: target) }
                    // 跟控制条交互过：自动收起的计时从头算（M03P10）。
                    scheduleControlsAutoHide()
                }
            )
            .tint(.white)
            Text(Self.timeText(latestDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    /// 动作行（M27 首验之三按参考图对齐）：播放 / 暂停 · 下一集 —— 右侧菜单
    /// （播放器 / 字幕 / 视轨 / 片头片尾 / 选集；音轨只有**两条以上**才多一颗，见 `audioMenu`）。
    ///
    /// 极简版（`minimal`）：只有播放 / 暂停 + 右下角那颗「全屏」—— 参考里圈住的就是这两颗。
    /// 「全屏」那颗**永远在最右**（就地那块两套版式都在右下角；全屏那层没有它，参考图里也没有）。
    private func transportRow(compact: Bool, minimal: Bool) -> some View {
        HStack(spacing: compact ? Self.barCompactSpacing : 22) {
            barIcon(playerState.isPlaying ? "pause.fill" : "play.fill", label: playerState.isPlaying ? "暂停" : "播放") {
                Task { await togglePlayback() }
            }
            if minimal {
                Spacer(minLength: 0)
            } else {
                if let next = nextEpisodeIndex {
                    barIcon("forward.end.fill", label: "下一集") {
                        Task { await switchEpisode(to: next) }
                    }
                }
                Spacer(minLength: 0)
                engineMenu(compact: compact)
                subtitleMenu(compact: compact)
                videoMenu(compact: compact)
                audioMenu(compact: compact)
                openingEndingMenu(compact: compact)
                if playlist != nil {
                    barTextButton("选集", icon: "list.bullet", compact: compact) {
                        isEpisodeDrawerPresented = true
                    }
                }
            }
            fullScreenButton
        }
    }

    /// 右下角那颗「全屏」（参考同位置）：进全屏那层，并顺手把屏幕翻成横屏
    /// （iOS 16+ 才有公开 API；翻不了就不翻 —— 全屏那层的按钮**始终**是完整的）。
    /// 它是动作行的**最后一颗**（就地那块两套版式都在右下角）；全屏那层不给
    /// `onRequestFullScreen` 回传，所以那边没有它（参考图里也没有）。
    @ViewBuilder
    private var fullScreenButton: some View {
        if let onRequestFullScreen {
            barIcon("arrow.up.left.and.arrow.down.right", label: "全屏播放") {
                if PlatformShims.isPlaybackLandscape() == false {
                    PlatformShims.requestPlaybackOrientation(landscape: true)
                }
                onRequestFullScreen()
            }
        }
    }

    /// 关播放：就地播放清掉那块画面，推页 / 全屏退回 `dismiss`（见 `PlaybackView/onClose`）。
    func closePlayback() {
        if let onClose {
            onClose()
        } else {
            dismissPlayback()
        }
    }

    /// 锁 / 解锁按钮（M03P21）：锁上之后控制条只剩它，点一下切换并把控制条亮出来。
    var lockButton: some View {
        Button {
            isLocked.toggle()
            showControls()
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLocked ? "解锁" : "锁定画面")
    }

    /// 进度条绑定：拖动只改界面上的位置（松手才真 seek，见 ``progressRow``）。
    var seekBinding: Binding<Double> {
        Binding(
            get: { latestPosition },
            set: { newValue in latestPosition = newValue }
        )
    }

    // MARK: - 参数徽标

    /// 底排那排参数徽标（参考图：`HW HDR H265 4K 25FPS 5.6Mbps`）—— **只报读得到的**，
    /// 读不到就不占位置（与信息区「播放信息」同一口径）。
    var statBadges: [String] {
        guard let stats = playbackStats, !stats.isEmpty else {
            return []
        }
        var badges: [String] = []
        if stats.decodeText.contains("硬") {
            badges.append("HW")
        } else if !stats.decodeText.isEmpty {
            badges.append("SW")
        }
        if stats.dynamicRangeText.uppercased().contains("HDR") {
            badges.append("HDR")
        }
        if let codec = Self.shortCodec(stats.codecText) {
            badges.append(codec)
        }
        if let size = Self.shortResolution(stats.resolutionText) {
            badges.append(size)
        }
        if let fps = Self.shortFPS(stats.fpsText) {
            badges.append(fps)
        }
        if !stats.bitrateText.isEmpty {
            badges.append(stats.bitrateText)
        }
        return badges
    }

    /// 编码短名：`hevc · yuv420p10` → `H265`（认不出来的取第一个词大写）。
    static func shortCodec(_ text: String) -> String? {
        let head = text.split(separator: "·").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !head.isEmpty else {
            return nil
        }
        switch head.lowercased() {
        case "hevc", "h265":
            return "H265"
        case "h264", "avc":
            return "H264"
        default:
            return head.uppercased()
        }
    }

    /// 分辨率短名：`3840×2160` → `4K`、`1920×1080` → `1080P`、`1280×720` → `720P`，其余原样。
    static func shortResolution(_ text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }
        let head = text.split(whereSeparator: { $0 == "×" || $0 == "x" || $0 == "*" }).first.map(String.init) ?? ""
        guard let width = Int(head.trimmingCharacters(in: .whitespaces)) else {
            return text
        }
        switch width {
        case 3800...:
            return "4K"
        case 1900 ..< 3800:
            return "1080P"
        case 1200 ..< 1900:
            return "720P"
        default:
            return text
        }
    }

    /// 帧率短名：`23.976` → `24FPS`（取整，与参考的 `25FPS` 同款）。
    static func shortFPS(_ text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return text
        }
        return "\(Int(value.rounded()))FPS"
    }
}
