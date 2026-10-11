import CatVodCore
import CatVodPlayer
import CatVodSource
import SwiftUI

// 设置页的「播放」子页。
//
// 约定（与 `docs/任务记录/M02P11-设置页与追剧页.md` 一致）：
// 能用真实数据的就用真实数据；暂时没有的一律**写明缺什么 + 属于哪个里程碑**，
// 不静默失败、也不做「点了没反应」的假开关。

// MARK: - 播放器

/// 播放器：默认播放器（点开是内核菜单，就地切换）+ 三个子页（内核 / 播放界面 / 播放控制）。
///
/// 结构对齐参考图：第一行是「默认播放器 + 当前值（蓝字）」，**点它出内核菜单** ——
/// 此前这里只是个死标签（点蓝字没反应，真正的入口是下面一行重名的内核名），用户报过这一处。
/// 第二行「内核」进去是内核与解码设置 —— 与「源地址 → 接口管理」共用 ``PlaybackSettingsSection``。
@MainActor
struct SettingsPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                // 第一行既是「当前值」，也是切换入口：点它出内核菜单（此前是个死标签 ——
                // 点蓝字没反应，真正的入口是下面一行重名的内核名；用户报过这一处）。
                Menu {
                    Picker("默认播放器", selection: $model.preferredEngine) {
                        ForEach(PlayerEngineKind.allCases, id: \.self) { kind in
                            Text(kind.settingsTitle).tag(kind)
                        }
                    }
                } label: {
                    HStack {
                        // 显式定色：Menu 会把自己的 tint 刷到整个 label 上 —— 不加这一句，
                        // 左半边「默认播放器」也会变蓝（用户截图指出，只有右侧的值该是蓝的）。
                        Text("默认播放器")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text(model.preferredEngine.displayName)
                            .foregroundStyle(PlatformShims.accent)
                    }
                    .contentShape(Rectangle())
                }
                NavigationLink {
                    SettingsPlayerEngineView(model: model)
                } label: {
                    Text("内核")
                }
                NavigationLink {
                    SettingsPlayerUISettingsView(model: model)
                } label: {
                    Text("播放界面")
                }
                NavigationLink {
                    SettingsPlayerControlView(model: model)
                } label: {
                    Text("播放控制")
                }
            } footer: {
                // 这一页的第一行就是换内核的入口 —— 生效时机那句话在这里也得有（M24P1）。
                Text(PlaybackSettingsSection.appliesOnNextPlaybackNote)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放器")
    }
}

/// 播放内核：内核 + 解码方式 + 本地代理（与接口管理页共用同一区块）。
@MainActor
struct SettingsPlayerEngineView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackSettingsSection(model: model)
        }
        .adaptiveListStyle()
        .navigationTitle("播放内核")
    }
}

/// 播放界面：播放页的显示方式。
///
/// 与「设置 → 播放 → 播放页」共用 ``PlaybackPageSettingsSection``，
/// 避免两处各写一份 Picker 而出现「两个页面显示的视图不一样」。
@MainActor
struct SettingsPlayerUISettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackPageSettingsSection(model: model)
            Section("说明") {
                Text("三个内核（系统 / MPV / 自研 FFmpeg）共用同一条播放控制条与同一套画面手势"
                    + "（双击暂停 / 横拖进度 / 纵拖音量 / 长按加速 / 捏合缩放 / 上下滑换集，M27 起系统内核也一样）；"
                    + "各按钮只在内核真做得到时出现：画面比例八档（适应屏幕 / 裁剪全屏 / 拉伸全屏 / 4:3 / 5:4 / 16:9 / 21:9 / 2.39:1）"
                    + "三个内核都有；视轨只有 MPV，音量增益 MPV 与自研 FFmpeg；投屏与画中画不做。"
                    + "自研 FFmpeg 内核（M04P13 起可播）严格按设置的解码方式：硬解不可用时播放页会明确提示、"
                    + "让你改成软解（不自动降级）；字幕只出字、样式不还原，位图轨不做（M04P19）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放界面")
    }
}

/// 播放控制（M28，对齐参考的「播放控制」页）：画面手势的**开关与动作** +
/// 快进步长 / 控制中心 / 片头片尾自动跳 —— 三个内核共用一份（``PlaybackControlSettings``）。
///
/// 与「播放界面」那一页的分工：那边管**显示排布**（精简 / TMDB、自动播放），这边管**手上怎么做**
/// （单击 / 双击 / 滑动 / 震动）。改完在**下次进播放页**时生效 —— 与「播放内核 / 解码方式」同一口径
/// （M24P1）：正在播的那一页不中途换手势。
@MainActor
struct SettingsPlayerControlView: View {
    @ObservedObject var model: AppModel

    /// 播放控制设置：本页是它的**编辑入口**，改一下就落盘（`onChange`）。
    @State private var control = PlaybackControlBook.load()
    /// 两个倍速是另一条老线（`PlaybackSpeedBook`）—— 与播放页信息区的滑杆共用同一把存档，不复制。
    @State private var speed = PlaybackSpeedBook.speed()
    @State private var longPressSpeed = PlaybackSpeedBook.longPressSpeed()

    /// 长按倍速的档位：上游 `LONG_PRESS_MIN 2.0` 起、步进 0.5，到 5.0（与播放页那条滑杆同源）。
    private static let longPressPresets: [Float] = Array(stride(
        from: SpeedSetting.longPressMinimum,
        through: SpeedSetting.maximum,
        by: SpeedSetting.longPressStep
    ))

    var body: some View {
        List {
            Section {
                Picker("默认倍速", selection: speedBinding) {
                    ForEach(SpeedSetting.presets, id: \.self) { preset in
                        Text(SpeedSetting.format(preset)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Picker("长按倍速", selection: longPressSpeedBinding) {
                    ForEach(Self.longPressPresets, id: \.self) { preset in
                        Text(SpeedSetting.format(preset)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Picker("快进 / 快退步长", selection: $control.seekStepSeconds) {
                    ForEach(PlaybackControlSettings.seekStepOptions, id: \.self) { step in
                        Text("\(Int(step)) 秒").tag(step)
                    }
                }
                .pickerStyle(.menu)
                if PlaybackNowPlaying.isSupported {
                    Toggle("控制中心显示", isOn: $control.showsControlCenter)
                }
                Toggle("自动识别片头片尾", isOn: $control.autoOpeningEnding)
            } footer: {
                Text("「控制中心显示」= 在系统控制中心 / 锁屏显示剧名与进度，并能播放 / 暂停、上一集 / 下一集（画中画在播时让给系统那一份）。"
                    + "「自动识别片头片尾」= **用已标的**片头 / 片尾自动跳过与连播；音频指纹那类自动识别不做，标记还是手动标。")
            }

            // 标题 + footer 只能走「全闭包」那种写法：`Section("标题") { } footer: { }` 编不过
            // （编译器会把标题当成 content 闭包 —— 首验就红在这里）。
            Section {
                Picker("单击屏幕中间", selection: $control.singleTapCenter) {
                    ForEach(PlaybackTapAction.options, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.menu)
                if AdaptiveTapShim.supportsTapLocation {
                    Picker("单击屏幕两边", selection: $control.singleTapSides) {
                        ForEach(PlaybackTapAction.options, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("单击手势")
            } footer: {
                if !AdaptiveTapShim.supportsTapLocation {
                    Text("这个系统拿不到点按落点（要 iOS 16 起）：点按一律按「屏幕中间」处理，"
                        + "「屏幕两边」这一档不出现。")
                }
            }

            Section("双击手势") {
                Picker("双击屏幕中间", selection: $control.doubleTapCenter) {
                    ForEach(PlaybackTapAction.options, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.menu)
                if AdaptiveTapShim.supportsTapLocation {
                    Picker("双击屏幕两边", selection: $control.doubleTapSides) {
                        ForEach(PlaybackTapAction.options, id: \.self) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("滑动手势") {
                Toggle("滑动调节音量", isOn: $control.swipeVolume)
                Toggle("滑动调节亮度", isOn: $control.swipeBrightness)
                Toggle("滑动调节进度", isOn: $control.swipeSeek)
                Toggle("短剧滑动切集", isOn: $control.swipeEpisode)
            }

            if PlaybackHaptics.isSupported {
                Section("震动反馈") {
                    Toggle("长按屏幕", isOn: $control.hapticLongPress)
                    Toggle("滑动调节亮度", isOn: $control.hapticBrightness)
                    Toggle("滑动调节音量", isOn: $control.hapticVolume)
                    Toggle("滑动调节进度", isOn: $control.hapticSeek)
                }
            }

            Section {
                Button("恢复默认（全部手势与控制）") {
                    control = PlaybackControlSettings()
                }
            } footer: {
                Text("把这一页恢复成出厂那套：单击显隐控制条、双击播放 / 暂停、四条滑动与震动全开、"
                    + "步长 15 秒、控制中心显示开、片头片尾自动跳开。倍速那两项不受影响。")
            }

            Section("说明") {
                InfoRow(title: "当前内核", value: model.preferredEngine.displayName)
                Text("三个内核（系统 / MPV / 自研 FFmpeg）共用这一份：控制条与画面手势从 M27 起就是同一套，"
                    + "这里改的是「哪几条开着、点了干什么」—— 换内核不会换手感。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("「屏幕中间」= 画面宽度的中间一半，两侧 = 左右各四分之一（与「上滑 / 下滑切集」的分区一致）。"
                    + "「快进 / 快退」双击时**左半屏退、右半屏进**，步长就是上面那一项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("以上选项在**下次进播放页**时生效：正在播的那一页不中途换手势（与「播放内核 / 解码方式」同一口径）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放控制")
        .onChange(of: control) { settings in
            // 用户动作即落盘（与设置页其它项一致）；播放页在进页时读走。
            PlaybackControlBook.save(settings)
        }
    }

    /// 默认倍速：改一下写同一把存档（播放页进页时读它）。
    private var speedBinding: Binding<Float> {
        Binding(
            get: { speed },
            set: { value in
                speed = SpeedSetting.clamp(value)
                PlaybackSpeedBook.save(speed)
            }
        )
    }

    /// 长按倍速：同上（只有 2.0–5.0 那 7 档）。
    private var longPressSpeedBinding: Binding<Float> {
        Binding(
            get: { longPressSpeed },
            set: { value in
                longPressSpeed = SpeedSetting.clampLongPress(value)
                PlaybackSpeedBook.saveLongPressSpeed(longPressSpeed)
            }
        )
    }
}

// MARK: - 播放页

/// 播放页：显示视图 + 自动播放。
///
/// 结构对齐参考图的两行：`显示视图`（点开是「精简视图 / TMDB 视图」菜单）与
/// `自动播放`（副标题「首次进入是否自动选中第一集开始播放」）。
///
/// 两项都是**真实生效**的偏好：显示视图决定详情页的排布，
/// 自动播放决定进入详情页后是否直接开播（有「上次看到」的进度时以续播为准）。
@MainActor
struct SettingsPlaybackPageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            PlaybackPageSettingsSection(model: model)
            Section("说明") {
                Text("显示视图只换排布，数据与交互不变：\(model.playbackPageLayout.summary)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("自动播放只在「没有观看记录」时生效；有记录时按记录续播，不会把用户拉回第一集。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("播放页")
    }
}

/// 播放页设置区块：显示视图 + 自动播放。
///
/// 两个入口共用（避免两处各写一份 Picker）：
/// - 设置 → 播放 → 播放页（``SettingsPlaybackPageView``）；
/// - 设置 → 播放 → 播放器 → 播放界面（``SettingsPlayerUISettingsView``）。
@MainActor
struct PlaybackPageSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Picker("显示视图", selection: $model.playbackPageLayout) {
                ForEach(PlaybackPageLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: $model.autoPlayFirstEpisode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动播放")
                    Text("首次进入是否自动选中第一集开始播放")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 切到 TMDB 视图才要求填（M11）：元信息那一层的三个入口。
            // 不填也能用 —— 只是那一层不工作、详情页显示占位，不弹错。
            if model.playbackPageLayout == .tmdb {
                TextField("TMDB api key", text: $model.tmdbConfig.apiKey)
                TextField("api 代理地址（可空）", text: $model.tmdbConfig.apiProxy)
                TextField("图片代理地址（可空）", text: $model.tmdbConfig.imageProxy)
                Text(model.isTMDBConfigured
                    ? "元信息已可用：标题、简介、图集都从 TMDB 取。"
                    : "没填 api key —— 元信息这一层不工作，界面显示占位。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // 取图模式：顶部背景图现在就用它；选集卡片随后接同一套（PosterPicker 已共用）。
                Picker("海报方式", selection: $model.tmdbPosterMode) {
                    ForEach(PosterMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text("随机是**进页面定一次**，不是每张都在跳 —— 每张都换会像坏了。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 弹幕 API（解析器）

/// 弹幕显示：字号 / 透明度 / 速度 / 显示区域（M08i；控件在 M03P24 与播放页快捷面板共用）。
///
/// 四项都**即时生效**：改一次写一次 `UserDefaults`，播放页重排计划时读到 ——
/// 播放中把字号调大，下一帧就变大，不用退出重进。
///
/// 这一页现在只剩「说明 + 一组共用控件」（``DanmakuDisplayControls``）：播放页的「弹幕设置」
/// 快捷面板用的是同一组控件、同一份配置 —— 两个面一样，才不会有「设置页调的跟播放页调的不一样」。
@MainActor
struct SettingsDanmakuDisplayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                Text("这里只管**本机的显示**：弹幕从哪儿取见「弹幕 API」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DanmakuDisplayControls(config: $model.danmakuDisplay)
        }
        .adaptiveListStyle()
        .navigationTitle("弹幕显示")
    }
}

/// 弹幕 API：启用开关 + 四个地址槽位（结构对齐参考图）。
///
/// 参考图的做法是「用户自己填 1…4 个弹幕接口地址」，副标题写明「开启后将禁用视频源的弹幕功能」。
/// 我们这里把地址**真实保存**（`UserDefaults`，重启后仍在）：取回见 M08c、上屏见 M08h，
/// 填好地址进播放页就会有弹幕。显示参数（字号 / 透明度 / 速度 / 区域）在「弹幕显示」页。
///
/// 配置里声明的解析器（`parses`）另列一组：那是「这个源能解析什么」，
/// 与「用户自选弹幕 API」是两件事，不该混在一处展示。
@MainActor
struct SettingsDanmakuAPIView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                Toggle(isOn: $model.danmakuAPI.isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用弹幕 API")
                        Text("开启后将禁用视频源的弹幕功能")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 四个槽位各成一组（对齐参考图的 `API-1` … `API-4`）：顺序固定，不随输入变化。
            ForEach(0 ..< DanmakuAPIConfig.slotCount, id: \.self) { index in
                Section("API-\(index + 1)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API-\(index + 1)")
                        TextField("API 地址", text: addressBinding(index))
                    }
                }
            }

            Section("说明") {
                Text("四个地址保存在本机（重启后仍在）。填好地址并启用后，进播放页就会去搜索并上屏"
                    + "（取回见 M08c、上屏见 M08h）；显示参数在「弹幕显示」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if parsers.isEmpty {
                Section("接口解析器（parses）") {
                    Text(emptyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("接口解析器（parses）") {
                    ForEach(parsers) { parser in
                        row(for: parser)
                    }
                }
            }

            Section("现状") {
                Text("解析链本身（`parse`/`jx`）与 Web 嗅探在 M5 实现，弹幕与字幕的渲染在 M8。也就是说：这里能看到接口声明了哪些解析器，但播放时还不会自动去调它们。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveListStyle()
        .navigationTitle("弹幕 API")
    }

    /// 某个槽位的地址绑定：读写在 `AppModel.danmakuAPI` 上（`@Published`，写一次就落 `UserDefaults`）。
    private func addressBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.danmakuAPI.address(at: index) },
            set: { model.danmakuAPI.setAddress($0, at: index) }
        )
    }

    private func row(for parser: ParserRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(parser.name.isEmpty ? "未命名解析器" : parser.name)
                Spacer()
                Text(kindText(parser))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !parser.url.isEmpty {
                Text(parser.url)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let reason = parser.availability.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var parsers: [ParserRule] {
        model.state.loadedSource?.config.parses ?? []
    }

    /// 解析器类型的中文名（JAR 两类明确标注不支持）。
    ///
    /// 注意两点（都是 lint 约定）：
    /// - `switch` 表达式的隐式返回只允许出现在「整个函数体就是那一个表达式」时，这里前面还有语句，所以每条分支显式 `return`；
    /// - 不在 `switch` 里做可选值匹配（`case .some(.web)`），先 `guard let` 拿到非可选枚举再分支。
    private func kindText(_ parser: ParserRule) -> String {
        guard let kind = parser.kind else {
            return "type=\(parser.type)"
        }
        switch kind {
        case .web:
            return "Web 嗅探"
        case .json:
            return "JSON 解析"
        case .jarJson:
            return "JAR Json（不支持）"
        case .jarMix:
            return "JAR Mix（不支持）"
        case .aggregate:
            return "聚合解析"
        }
    }

    private var emptyHint: String {
        if let reason = model.state.failureReason {
            return "接口加载失败：\(reason)"
        }
        return "当前接口没有解析器（`parses` 为空），或还没有加载接口。"
    }
}
