import CatVodPlayer
import SwiftUI

/// 播放页叠层控制条的**菜单与小件**（M27 首验之二从 `PlaybackView+Controls.swift` 拆出）。
///
/// 为什么拆：`+Controls` 的类型体又贴到 SwiftLint `type_body_length` 的 error 线（450）——
/// 与 `+Speed` / `+Gestures` / `+Tracks` 同一套做法（拆职责，不拆碎）。
/// 跨文件用到的成员**不能写 `private`**（`private` 是文件作用域）：本次跨文件的就是那几个
/// 「菜单 / 按钮」本体（`scaleMenu` / `engineMenu` / `barIcon` / `barTextButton` 等），
/// 其余（两个 Binding 与几个小件）还是 `private`。
extension PlaybackView {
    // MARK: - 顶排那几个菜单

    /// 画面比例：只列**当前内核真的支持**的档位（内核一档都不支持时这颗不出现）。
    @ViewBuilder
    var scaleMenu: some View {
        let modes = PlaybackScaleMode.supportedModes(by: engineKind)
        if !modes.isEmpty {
            Menu {
                Picker("画面比例", selection: scaleBinding) {
                    ForEach(modes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } label: {
                // 图标按参考图那颗「画面比例」（方框 + 箭头）；斜箭头留给「全屏」那颗。
                barIconLabel("aspectratio")
            }
            .accessibilityLabel("画面比例")
        }
    }

    /// 弹幕：开关 + 搜索 + 设置（参考图那颗「弹」）。
    @ViewBuilder
    var danmakuMenu: some View {
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
    var speedMenu: some View {
        if engine != nil {
            Menu {
                Picker("倍速", selection: speedPickerBinding) {
                    ForEach(SpeedSetting.presets, id: \.self) { preset in
                        Text(SpeedSetting.format(preset)).tag(preset)
                    }
                }
            } label: {
                barIconLabel("speedometer")
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
    var rotateButton: some View {
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
    func engineMenu(compact: Bool) -> some View {
        if availableEngineKinds.count > 1 {
            barMenu("播放器", icon: "play.rectangle", compact: compact) {
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
    func subtitleMenu(compact: Bool) -> some View {
        if !subtitleTracks.isEmpty {
            barMenu("字幕", icon: "captions.bubble", compact: compact) {
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

    /// 视轨（M26；M28 收尾改成**两条以上**才出现）：只有一条时菜单里是「自动 + 那一条」，
    /// 等于没得选 —— 与音轨同一条规矩（不摆没用的开关）。普通片子三个内核因此都不摆这一颗，
    /// 多视频轨的片源里 MPV 报得出两条以上才出现（系统 / 自研内核报不出第二条，照旧不出现）。
    @ViewBuilder
    func videoMenu(compact: Bool) -> some View {
        if videoTracks.count > 1 {
            barMenu("视轨", icon: "rectangle.on.rectangle", compact: compact) {
                Picker("视轨", selection: videoSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(videoTracks) { track in
                        Text(track.label ?? "视轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 音轨：**两条以上才出现** —— 只有一条时菜单里是「自动 + 那一条」，等于没得选
    /// （不摆点了没用的开关；参考图里也没有这颗）。要换音轨还有信息区的「轨道」那一段。
    @ViewBuilder
    func audioMenu(compact: Bool) -> some View {
        if audioTracks.count > 1 {
            barMenu("音轨", icon: "waveform", compact: compact) {
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
    func openingEndingMenu(compact: Bool) -> some View {
        if activeProgressContext != nil, latestDuration > 0 {
            barMenu("片头片尾", icon: "bookmark", compact: compact) {
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

    // MARK: - 小件

    /// 一颗图标按钮（白色、固定 30×30 —— 排布对齐参考里那排图标）。
    func barIcon(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
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

    /// 一个按钮（底排右侧）—— 宽版给文字、窄版给图标（动作一样）。
    func barTextButton(_ title: String, icon: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            barMenuLabel(title, icon: icon, compact: compact)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// 一个菜单（底排右侧）—— 宽版给文字、窄版给图标（菜单内容一样）。
    private func barMenu<Content: View>(
        _ title: String,
        icon: String,
        compact: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            barMenuLabel(title, icon: icon, compact: compact)
        }
        .accessibilityLabel(title)
    }

    /// 菜单 / 按钮共用的 label：宽版文字、窄版图标（窄版靠 `accessibilityLabel` 说名字）。
    @ViewBuilder
    private func barMenuLabel(_ title: String, icon: String, compact: Bool) -> some View {
        if compact {
            barIconLabel(icon)
        } else {
            barTextLabel(title)
        }
    }

    /// 宽版的文字 label（窄不下来先别硬撑 —— 该走图标版；这里只兜一层轻微缩放）。
    private func barTextLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .frame(height: 30)
    }
}
