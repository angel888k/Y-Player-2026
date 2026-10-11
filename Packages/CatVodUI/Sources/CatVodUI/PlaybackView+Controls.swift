import CatVodPlayer
import SwiftUI

/// 播放页的**叠层控制条**（M03P6 起；M26 按参考的全屏播放器重排；M27 起三个内核共用）。
///
/// 排布对齐参考截图（完整版）：
/// - 顶排**之上**：状态行（左时钟 · 中标题 · 右电量）—— 只给真·全屏（M28 首验之十四）；
/// - 顶排：关闭（✕）· 投屏 · 旋转 · 画面比例（**真·全屏里旋转 / 画面比例不摆**）—— 右侧：画中画 · 弹幕 · 倍速 · 锁定；
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
            if isTrueFullScreenPlayer {
                playbackStatusBar
            }
            if isLocked {
                HStack {
                    Spacer(minLength: 0)
                    lockButton
                }
                // 锁上时这条只剩解锁按钮：这一条自己吃掉点按 —— 点歪一点别穿到画面上去，
                // 不然「点解锁」会变成「把控制条藏了」（M28 首验之十）。
                .contentShape(Rectangle())
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

    // MARK: - 全屏顶上的状态行（M28 首验之十四）

    /// 是不是**真·全屏**：「全屏那一层」与「精简视图就地放大后的那块」（同一份控制条，两处差异都看它）——
    /// ① 顶上加**状态行**（时钟 · 标题 · 电量，M28 首验之十四）；
    /// ② 顶排**不摆「旋转 / 画面比例」**（M28 首验之十七，用户口径：全屏里这两颗用不上）。
    ///
    /// 判据是 `onRequestFullScreen == nil`：就地那块**没放大**时带着「转全屏」回传
    /// （放大后 `expandFullScreenAction` 给 nil，见 `VodDetailView+Compact.swift`）—— 那时才是全屏。
    var isTrueFullScreenPlayer: Bool {
        isFullScreen && onRequestFullScreen == nil
    }

    /// 状态行两侧（时钟 / 电量）各留的位宽（M28 首验之十五）：**等宽才谈得上「标题居中」** ——
    /// 电量读不到时（模拟器）右侧不塌成 0，标题照样落在正中间。
    static let statusSideWidth: CGFloat = 88

    /// 状态行（用户参考图）：左时钟 · 中标题 · 右电量 —— 排布与系统状态栏同款。
    /// 时钟一秒一跳（`TimelineView`）；电量变化慢，跟着这条一起挂在那儿，不单独轮询。
    ///
    /// 布局三份账（M28 首验之十六）：
    /// - 标题用 `ZStack` 对着**整条的正中**摆（两侧各留 ``statusSideWidth``，长了从中段截）；
    /// - 时钟 / 电量只做「位」的账，而且两侧的框都用**定宽**（`width:`）—— 不能用 `minWidth`：
    ///   `TimelineView` 这类容器**吃提议宽度**，跟 `minWidth` 的框凑一起会把左边吃胖、
    ///   把标题挤到右边（首验截图里标题比屏幕中心右偏约 60pt 就是这么来的）；
    /// - 时钟那截自己带 10pt 左内边距（用户口径：再往右挪一点），且算在**留位之内**，不带偏居中。
    var playbackStatusBar: some View {
        ZStack {
            Text(activeTitle)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, Self.statusSideWidth)
            HStack(spacing: 12) {
                clockLabel
                    .padding(.leading, 10)
                    .frame(width: Self.statusSideWidth, alignment: .leading)
                Spacer(minLength: 12)
                batteryLabel
                    .frame(width: Self.statusSideWidth, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
    }

    /// 时钟（一秒一跳）：闭包里只碰非隔离的纯函数 —— 别把 `TimelineView` 的闭包牵进主 actor 的账。
    private var clockLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.clockText(context.date))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }

    /// 电量（仿系统状态栏）：「53% + 电池图标」；**读不到就整截不画**（模拟器 / iOS 之外 —— 不写假话）。
    @ViewBuilder
    private var batteryLabel: some View {
        if let battery = PlatformShims.batteryStatus() {
            HStack(spacing: 4) {
                Text("\(Int((battery.level * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                Image(systemName: Self.batterySymbol(level: battery.level, charging: battery.charging))
            }
        }
    }

    /// 时钟文本（**纯函数**，有单测）：跟系统设置走（24 小时制「18:06」，12 小时制带 AM/PM）。
    /// `nonisolated`：`TimelineView` 的闭包是同步非隔离上下文，主 actor 的静态成员在那里调不得。
    nonisolated static func clockText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// 电量图标的 SF Symbol（**纯函数**，有单测）：25% 一档；充着电带 bolt。
    nonisolated static func batterySymbol(level: Double, charging: Bool) -> String {
        if charging {
            return "battery.100.bolt"
        }
        switch level {
        case ..<0.2: return "battery.0"
        case ..<0.45: return "battery.25"
        case ..<0.7: return "battery.50"
        case ..<0.95: return "battery.75"
        default: return "battery.100"
        }
    }

    /// 控制条窄到放不下文字按钮的宽度线。
    ///
    /// 宽版底排要 ~541pt（3 颗图标 90 + 六颗文字按钮 225 + 九个间隔 198 + 内边距 28）——
    /// 横屏（~844）与 iPad 都在线上；竖屏 iPhone（390 / 402 / 375）在线下。
    static let barCompactWidth: CGFloat = 560
    /// 窄版的间距（10：9 颗 30pt 图标 + 8 个间隔 + 两侧内边距 ≈ 378pt，留得住 390 / 402）。
    static let barCompactSpacing: CGFloat = 10

    /// 顶排（M27 首验之三按参考图对齐；M27 首验之十一按用户口径**三个内核一套按钮**）：
    /// 关闭 · 旋转 · 画面比例 —— 弹幕 · 倍速 · 锁定。
    /// **真·全屏里「旋转 / 画面比例」不摆**（M28 首验之十七，用户口径：全屏里这两颗用不上）——
    /// 非全屏那几套（推页 / 精简视图横屏 / iPad）照旧有。
    ///
    /// **投屏 / 画中画 不摆**（用户口径：以 MPV 全屏那套为准，系统内核也是同一套按钮）：
    /// 那两颗只有系统内核做得到（`AVRoutePickerView` / `AVPictureInPictureController`），
    /// 摆上去会让「换个内核按钮就变样」——三个内核一套按钮比多两颗能力更重要。
    /// 实现还留着（`PlaybackCast` / `PlaybackPip`）：画中画的**自动起**照旧工作（切后台时系统自己起），
    /// 要接回来只差把这两行加回去。
    private func topIconRow(compact: Bool) -> some View {
        HStack(spacing: compact ? Self.barCompactSpacing : 24) {
            barIcon("xmark", label: "关闭播放") {
                closePlayback()
            }
            if !isTrueFullScreenPlayer {
                rotateButton
                scaleMenu
            }
            Spacer(minLength: 0)
            danmakuMenu
            speedMenu
            lockButton
        }
        // 这条自己吃掉点按：点歪一点别穿到画面上去 —— 穿过去就是把控制条显隐掉，
        // 看上去像「按钮点了没反应」（M28 首验之十）。
        .contentShape(Rectangle())
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
        // 同上：这一条的空档也吃掉点按，别穿到画面上（按钮之间的空隙不是「画面」）。
        .contentShape(Rectangle())
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
