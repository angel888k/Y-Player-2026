import CatVodPlayer
import SwiftUI

/// 播放页自绘内核的**叠层控制条**（M03P6 起；M26 按参考的全屏播放器重排）。
///
/// 排布对齐参考截图：
/// - 顶排：关闭（✕）· 画面比例 —— 右侧：弹幕 · 倍速 · 锁定；
/// - 底排：参数徽标（`HW HDR H265 4K 25FPS 5.6Mbps`，**只报读得到的**）+「当前时间 · 进度条 · 总时长」，
///   再一行：播放 / 暂停 · 下一集 · 逐帧 —— 右侧四个文字按钮「字幕 / 音轨 / 片头片尾 / 选集」。
///
/// 参考里还有投屏 / 画中画 / 「播放器（内核切换）」/「视轨」四组我们**没有**的控件，
/// 照「不摆假开关」的规矩不出现（换内核在设置里、也没有视频轨选择）。
///
/// 为什么必须自绘：系统内核的控件是 `VideoPlayer` 自带的；自绘内核（MPV / 自研 FFmpeg）只有一层画面层，
/// 没有这条就只能看，不能停、不能拖。
///
/// 锁屏（M03P21）也落在这一条上：锁上之后**常规内容整块藏起来，只剩锁按钮** —— 上游 `control.right.lock` 同款。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Speed` / `+Gestures` / `+OpeningEnding` / `+Lines` 同一套做法。
extension PlaybackView {
    /// 整条叠层：顶排图标 + 底排（锁上时只剩锁按钮）。
    var playerControls: some View {
        VStack(spacing: 10) {
            if isLocked {
                HStack {
                    Spacer(minLength: 0)
                    lockButton
                }
            } else {
                topIconRow
                Spacer(minLength: 0)
                bottomControls
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

    /// 顶排：关闭 · 画面比例 —— 弹幕 · 倍速 · 锁定。
    private var topIconRow: some View {
        HStack(spacing: 24) {
            barIcon("xmark", label: "关闭播放") {
                closePlayback()
            }
            scaleMenu
            rotateButton
            if onRequestFullScreen != nil {
                barIcon("arrow.up.left.and.arrow.down.right", label: "全屏播放") {
                    onRequestFullScreen?()
                }
            }
            Spacer(minLength: 0)
            danmakuMenu
            speedMenu
            lockButton
        }
    }

    /// 底排：参数徽标 + 进度 + 动作行。
    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !statBadges.isEmpty {
                badgesRow
            }
            progressRow
            transportRow
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

    /// 动作行：播放 / 暂停 · 下一集 · 逐帧 —— 右侧文字按钮。
    private var transportRow: some View {
        HStack(spacing: 22) {
            barIcon(playerState.isPlaying ? "pause.fill" : "play.fill", label: playerState.isPlaying ? "暂停" : "播放") {
                Task { await togglePlayback() }
            }
            if let next = nextEpisodeIndex {
                barIcon("forward.end.fill", label: "下一集") {
                    Task { await switchEpisode(to: next) }
                }
            }
            barIcon("forward.frame", label: "逐帧步进") {
                Task { await engine?.stepFrame() }
            }
            Spacer(minLength: 0)
            engineMenu
            subtitleMenu
            videoMenu
            audioMenu
            openingEndingMenu
            if playlist != nil {
                barTextButton("选集") {
                    isEpisodeDrawerPresented = true
                }
            }
        }
    }

    // MARK: - 顶排那几个菜单

    /// 画面比例：只列**当前内核真的支持**的档位（系统内核一档都不支持，这颗按钮就不出现）。
    @ViewBuilder
    private var scaleMenu: some View {
        let modes = PlaybackScaleMode.supportedModes(by: engineKind)
        if !modes.isEmpty {
            Menu {
                Picker("画面比例", selection: scaleBinding) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } label: {
                barIconLabel("arrow.up.left.and.arrow.down.right")
            }
            .accessibilityLabel("画面比例")
        }
    }

    /// 弹幕：开关 + 搜索 + 设置（参考图那颗「弹」）。
    @ViewBuilder
    private var danmakuMenu: some View {
        if showsDanmakuSection {
            Menu {
                Toggle("显示弹幕", isOn: Binding(
                    get: { danmakuDisplay.isVisible },
                    set: { next in
                        var copy = danmakuDisplay
                        copy.isVisible = next
                        onDanmakuDisplayChanged?(copy)
                    }
                ))
                if danmakuSwitcher != nil {
                    Button("搜索弹幕…") {
                        isDanmakuPickerPresented = true
                    }
                }
                Button("弹幕设置…") {
                    isDanmakuSettingsPresented = true
                }
            } label: {
                Text("弹")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel("弹幕")
        }
    }

    /// 倍速：预设列表（改完当场生效，落盘在 `setSpeed` 里）。
    @ViewBuilder
    private var speedMenu: some View {
        if engine != nil {
            Menu {
                Picker("倍速", selection: speedPickerBinding) {
                    ForEach(SpeedSetting.presets, id: \.self) { preset in
                        Text(SpeedSetting.format(preset)).tag(preset)
                    }
                }
            } label: {
                barIconLabel("timer")
            }
            .accessibilityLabel("倍速")
        }
    }

    /// 倍速选择：只派活（`setSpeed` 里改内核 + 落盘），当前值不是预设时单纯不显示选中态。
    private var speedPickerBinding: Binding<Float> {
        Binding(
            get: { speed },
            set: { setSpeed($0, persist: true) }
        )
    }

    // MARK: - 底排那几个文字按钮

    /// 旋转（对齐参考顶排那颗）：把「横屏 ↔ 竖屏」翻一下。
    ///
    /// **只在有公开 API 的系统上出现**（iOS 16+）；iOS 15 / macOS 拿不到就不摆这颗
    /// （UI 规范第 5 条：没有公开 API 的能力不做）。
    @ViewBuilder
    private var rotateButton: some View {
        if PlatformShims.canRequestPlaybackOrientation {
            barIcon("rotate.right", label: "旋转屏幕") {
                let landscape = PlatformShims.isPlaybackLandscape() ?? true
                PlatformShims.requestPlaybackOrientation(landscape: !landscape)
            }
        }
    }

    /// 「播放器」：就地换内核（参考底排第一颗）。**只列现在真能用的**那一档以上 ——
    /// 一个可用内核都没有时整颗按钮不出现（不摆假选项，也不自动降级）。
    @ViewBuilder
    private var engineMenu: some View {
        if availableEngineKinds.count > 1 {
            barMenu("播放器") {
                Picker("播放器", selection: enginePickerBinding) {
                    ForEach(availableEngineKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
            }
        }
    }

    /// 现在能用的内核（`isAvailable` 是「引擎实装 + 依赖可用」那条口径）。
    var availableEngineKinds: [PlayerEngineKind] {
        PlayerEngineKind.allCases.filter(\.isAvailable)
    }

    /// 选内核：换内核是**异步重载**（拆 + 建 + 续播），所以绑定只派活（真正的活在 `switchEngine(to:)`）。
    private var enginePickerBinding: Binding<PlayerEngineKind> {
        Binding(
            get: { engineKind },
            set: { kind in
                Task { await switchEngine(to: kind) }
            }
        )
    }

    /// 字幕：轨列表 + 关闭（**内核报了字幕轨才出现** —— 不做「点不动的假菜单」）。
    @ViewBuilder
    private var subtitleMenu: some View {
        if !subtitleTracks.isEmpty {
            barMenu("字幕") {
                Picker("字幕", selection: subtitleSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    Text("关闭").tag(TrackSelection.disabled)
                    ForEach(subtitleTracks) { track in
                        Text(track.label ?? "字幕 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 视轨（M26）：只在内核报了视轨时出现 —— MPV 会报（含多视频轨的片源），系统内核一般没有。
    @ViewBuilder
    private var videoMenu: some View {
        if !videoTracks.isEmpty {
            barMenu("视轨") {
                Picker("视轨", selection: videoSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(videoTracks) { track in
                        Text(track.label ?? "视轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 音轨：同上，只在内核报了音轨时出现。
    @ViewBuilder
    private var audioMenu: some View {
        if !audioTracks.isEmpty {
            barMenu("音轨") {
                Picker("音轨", selection: audioSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(audioTracks) { track in
                        Text(track.label ?? "音轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 片头片尾：标记 / 清除（没有进度记录或时长未知时不出现，与信息区那条同一口径）。
    @ViewBuilder
    private var openingEndingMenu: some View {
        if activeProgressContext != nil, latestDuration > 0 {
            barMenu("片头片尾") {
                if openingMark > 0 {
                    Button("清除片头") {
                        clearOpening()
                    }
                } else {
                    Button("标记片头") {
                        markOpening()
                    }
                    .disabled(!PlaybackOpeningEndingRules.canSetOpening(position: latestPosition, duration: latestDuration))
                }
                if endingMark > 0 {
                    Button("清除片尾") {
                        clearEnding()
                    }
                } else {
                    Button("标记片尾") {
                        markEnding()
                    }
                    .disabled(!PlaybackOpeningEndingRules.canSetEnding(position: latestPosition, duration: latestDuration))
                }
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

    // MARK: - 小件

    /// 一颗图标按钮（白色、固定 30×30 —— 排布对齐参考里那排图标）。
    private func barIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barIconLabel(systemName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// 图标本体（菜单的 label 也要用同一套尺寸 / 颜色）。
    private func barIconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.title3)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
    }

    /// 一个文字按钮（底排右侧那四个）。
    private func barTextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barTextLabel(title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 文字菜单（底排右侧那四个里的菜单）。
    private func barMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            barTextLabel(title)
        }
        .accessibilityLabel(title)
    }

    /// 文字按钮 / 文字菜单共用的 label。
    private func barTextLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.white)
            .frame(height: 30)
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
