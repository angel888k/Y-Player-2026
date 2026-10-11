import Foundation

/// 播放控制设置（设置 → 播放器 → 播放控制，M28）：**三个内核共用这一份手势与控制偏好**。
///
/// 为什么要有它：控制条与手势从 M27 起三个内核共用（系统 / MPV / 自研 FFmpeg），
/// 但「单击 / 双击各干什么、哪些滑动开着、要不要震动」一直写死在代码里。
/// 参考图（播放控制页）把这些摆成用户可调项 —— 这一份就是那份偏好的**唯一载体**：
/// 播放页进页时读一次（`PlaybackView/start()`），三个内核吃同一份，不再各写各的。
///
/// 生效时机与「播放内核 / 解码方式」同一口径（M24P1）：**进播放页时读走**，此后本次播放不中途变
/// —— 改了设置想立刻生效，退出播放页再进一次。
///
/// 与 ``PlaybackSpeedBook``（默认倍速 / 长按倍速）的分工：倍速那条线更早（M03P12 / M03P13），
/// 存档与播放页的滑杆共用；这一份只管手势与控制，两把键互不覆盖。
struct PlaybackControlSettings: Sendable, Equatable, Hashable {
    /// 快进 / 快退步长（秒）：双击分区选了「快进 / 快退」时，一次跳多少。
    var seekStepSeconds: Double
    /// 「控制中心显示」：把正在播的剧名 / 进度 / 播放状态发布到系统控制中心与锁屏，
    /// 并把「播放 / 暂停 / 上一集 / 下一集」接回播放页（见 `PlaybackNowPlaying`）。
    var showsControlCenter: Bool
    /// 「自动识别片头片尾」：**用已有标记自动跳** —— 开播跳到「片头」处、播到「片尾」自动下一集。
    ///
    /// 口径说清：音频指纹那类「自动识别出片头片尾」上游也没有（M03P16 拍板不做）；
    /// 这一项管的是**自动用**已标记的两个点 —— 关掉后标记照旧留着、也能手动标，只是不自动跳。
    var autoOpeningEnding: Bool
    /// 单击屏幕**中间一半**（宽度的 1/4 … 3/4，与「纵甩切集」同一分区）的动作。
    var singleTapCenter: PlaybackTapAction
    /// 单击屏幕**两侧**（中间一半之外）的动作。
    var singleTapSides: PlaybackTapAction
    /// 双击屏幕中间一半的动作。
    var doubleTapCenter: PlaybackTapAction
    /// 双击屏幕两侧的动作。
    var doubleTapSides: PlaybackTapAction
    /// 滑动调节音量（右半屏纵拖）。
    var swipeVolume: Bool
    /// 滑动调节亮度（左半屏纵拖）。
    var swipeBrightness: Bool
    /// 滑动调节进度（横拖）。
    var swipeSeek: Bool
    /// 短剧滑动切集（中间一半纵甩换集）。
    var swipeEpisode: Bool
    /// 震动反馈：长按屏幕（识别到长按加速那一下）。
    var hapticLongPress: Bool
    /// 震动反馈：滑动调节亮度（每跨 1% 一下）。
    var hapticBrightness: Bool
    /// 震动反馈：滑动调节音量（每跨 1% 一下）。
    var hapticVolume: Bool
    /// 震动反馈：滑动调节进度（每跨 1 秒一下）。
    var hapticSeek: Bool

    /// 快进 / 快退的档位（秒）—— 界面照它列，存档值也照它夹。
    static let seekStepOptions: [Double] = [10, 15, 30, 60]
    /// 步长的合法区间（手改 plist / 旧版本写坏的值都从这里过）。
    static let seekStepRange: ClosedRange<Double> = 5 ... 120

    /// 默认值 = **M28 之前的行为**（回归基线）：单击显隐控制条、双击播放暂停、
    /// 四条滑动全开、震动全开、步长 15 秒。不碰设置就什么都不变，有单测钉住。
    init(
        seekStepSeconds: Double = 15,
        showsControlCenter: Bool = true,
        autoOpeningEnding: Bool = true,
        singleTapCenter: PlaybackTapAction = .toggleControls,
        singleTapSides: PlaybackTapAction = .toggleControls,
        doubleTapCenter: PlaybackTapAction = .playPause,
        doubleTapSides: PlaybackTapAction = .playPause,
        swipeVolume: Bool = true,
        swipeBrightness: Bool = true,
        swipeSeek: Bool = true,
        swipeEpisode: Bool = true,
        hapticLongPress: Bool = true,
        hapticBrightness: Bool = true,
        hapticVolume: Bool = true,
        hapticSeek: Bool = true
    ) {
        self.seekStepSeconds = Self.clampSeekStep(seekStepSeconds)
        self.showsControlCenter = showsControlCenter
        self.autoOpeningEnding = autoOpeningEnding
        self.singleTapCenter = singleTapCenter
        self.singleTapSides = singleTapSides
        self.doubleTapCenter = doubleTapCenter
        self.doubleTapSides = doubleTapSides
        self.swipeVolume = swipeVolume
        self.swipeBrightness = swipeBrightness
        self.swipeSeek = swipeSeek
        self.swipeEpisode = swipeEpisode
        self.hapticLongPress = hapticLongPress
        self.hapticBrightness = hapticBrightness
        self.hapticVolume = hapticVolume
        self.hapticSeek = hapticSeek
    }

    /// 夹进步长区间：`NaN` 回默认、其余按大小夹（与 `SubtitleDisplayConfig.clamp` 同一口径）。
    static func clampSeekStep(_ value: Double) -> Double {
        guard !value.isNaN else {
            return 15
        }
        return min(max(value, seekStepRange.lowerBound), seekStepRange.upperBound)
    }

    /// 一次点按该干什么（**纯函数**，有单测）：双击 / 单击 + 落在哪一区 → 动作。
    ///
    /// 分区判定与「纵甩切集」共用一条（`PlaybackSwipeRules/isCenterZone`）：中间一半 = 中间，
    /// 两侧四分之一 = 两边 —— 手上不按屏幕分区，规则就必须是同一份。
    func tapAction(doubleTap: Bool, isCenter: Bool) -> PlaybackTapAction {
        switch (doubleTap, isCenter) {
        case (false, true): singleTapCenter
        case (false, false): singleTapSides
        case (true, true): doubleTapCenter
        case (true, false): doubleTapSides
        }
    }
}

/// 单击 / 双击能选的动作。
enum PlaybackTapAction: Int, Sendable, CaseIterable, Hashable {
    /// 显示 / 隐藏控制条。
    case toggleControls = 1
    /// 播放 / 暂停。
    case playPause = 2
    /// 快进 / 快退：**左半屏退、右半屏进**，步长见 ``PlaybackControlSettings/seekStepSeconds``。
    case seek = 3
    /// 什么都不做。
    case none = 4

    /// 界面上的名字（设置页的行与菜单都读它）。
    var title: String {
        switch self {
        case .toggleControls: "显示 / 隐藏控制条"
        case .playPause: "播放 / 暂停"
        case .seek: "快进 / 快退"
        case .none: "无"
        }
    }

    /// 四个分区（单击 / 双击 × 中间 / 两边）共用同一份可选动作 —— 单击也可以设成快进，
    /// 双击也可以设成显隐控制条；选项一样多、菜单一样长，不按分区拆两份。
    static let options: [PlaybackTapAction] = [.toggleControls, .playPause, .seek, .none]
}

/// 震动反馈的刻度闸（**纯逻辑**，有单测）：值每跨过一格才震一次。
///
/// 为什么要有它：亮度 / 音量 / 进度在一次拖动里会来几十个中间值 —— 每个都震是「嗡嗡嗡」，
/// 不是反馈；「跨 1% / 跨 1 秒震一下」才像刻度。第一次（按下那一刻）不震：那一下手指已经感觉到了。
struct PlaybackHapticTickGate: Equatable {
    /// 上一次震到的刻度；nil = 还没记过。
    private var lastTick: Int?

    /// 值（已按刻度取整）变了就记下来；返回 true = 该震这一下。
    mutating func shouldTick(_ tick: Int) -> Bool {
        guard let last = lastTick else {
            lastTick = tick
            return false
        }
        guard tick != last else {
            return false
        }
        lastTick = tick
        return true
    }
}

/// 三条刻度闸（亮度 / 音量 / 进度各记各的）：拖动是三选一的，但一次播放里三条都会用到。
struct PlaybackHapticGates: Equatable {
    private var brightness = PlaybackHapticTickGate()
    private var volume = PlaybackHapticTickGate()
    private var seek = PlaybackHapticTickGate()

    /// 亮度：0...1 → 百分比刻度。
    mutating func shouldTickBrightness(_ value: Double) -> Bool {
        brightness.shouldTick(Int((value * 100).rounded()))
    }

    /// 音量：0...1 → 百分比刻度。
    mutating func shouldTickVolume(_ value: Double) -> Bool {
        volume.shouldTick(Int((value * 100).rounded()))
    }

    /// 进度：秒 → 整秒刻度。
    mutating func shouldTickSeek(_ seconds: Double) -> Bool {
        seek.shouldTick(Int(seconds.rounded()))
    }
}

// MARK: - 持久化

extension PlaybackControlSettings {
    /// 落 `UserDefaults` 的形态：15 个字段用竖线拼接（与字幕 / 弹幕显示同一套）。
    ///
    /// 顺序即契约：步长 | 控制中心 | 片头片尾 | 单击中 | 单击边 | 双击中 | 双击边 |
    /// 滑音量 | 滑亮度 | 滑进度 | 滑切集 | 震长按 | 震亮度 | 震音量 | 震进度。
    var persistenceValue: String {
        [
            String(seekStepSeconds),
            showsControlCenter ? "1" : "0",
            autoOpeningEnding ? "1" : "0",
            String(singleTapCenter.rawValue),
            String(singleTapSides.rawValue),
            String(doubleTapCenter.rawValue),
            String(doubleTapSides.rawValue),
            swipeVolume ? "1" : "0",
            swipeBrightness ? "1" : "0",
            swipeSeek ? "1" : "0",
            swipeEpisode ? "1" : "0",
            hapticLongPress ? "1" : "0",
            hapticBrightness ? "1" : "0",
            hapticVolume ? "1" : "0",
            hapticSeek ? "1" : "0",
        ].joined(separator: "|")
    }

    /// 从 `UserDefaults` 的字符串还原；格式不对时**整体**回落默认（与字幕 / 弹幕显示同一口径）。
    static func decode(_ raw: String?) -> PlaybackControlSettings {
        guard let raw, !raw.isEmpty else {
            return PlaybackControlSettings()
        }
        let fields = raw.components(separatedBy: "|")
        guard fields.count == 15,
              let seekStep = Double(fields[0]),
              let singleCenterRaw = Int(fields[3]),
              let singleCenter = PlaybackTapAction(rawValue: singleCenterRaw),
              let singleSidesRaw = Int(fields[4]),
              let singleSides = PlaybackTapAction(rawValue: singleSidesRaw),
              let doubleCenterRaw = Int(fields[5]),
              let doubleCenter = PlaybackTapAction(rawValue: doubleCenterRaw),
              let doubleSidesRaw = Int(fields[6]),
              let doubleSides = PlaybackTapAction(rawValue: doubleSidesRaw)
        else {
            return PlaybackControlSettings()
        }
        return PlaybackControlSettings(
            seekStepSeconds: seekStep,
            showsControlCenter: fields[1] == "1",
            autoOpeningEnding: fields[2] == "1",
            singleTapCenter: singleCenter,
            singleTapSides: singleSides,
            doubleTapCenter: doubleCenter,
            doubleTapSides: doubleSides,
            swipeVolume: fields[7] == "1",
            swipeBrightness: fields[8] == "1",
            swipeSeek: fields[9] == "1",
            swipeEpisode: fields[10] == "1",
            hapticLongPress: fields[11] == "1",
            hapticBrightness: fields[12] == "1",
            hapticVolume: fields[13] == "1",
            hapticSeek: fields[14] == "1"
        )
    }
}

/// 播放控制设置的存档（`UserDefaults` 键 `yplayer.playbackControl`）。
///
/// 与 ``PlaybackSpeedBook`` 同一套做法：读的时候坏存档（格式不对 / 认不出的动作）**整体**回落默认，
/// 写的时候先夹紧 —— 手改 plist、旧版本写进去的值都不该把界面搞成没法用的样子。
enum PlaybackControlBook {
    /// 存档键；`internal` 而不是 `private`：单测要往同一个键写脏值，验证「坏存档 ⇒ 默认」。
    static let defaultsKey = "yplayer.playbackControl"

    /// 读取（没有存档 / 坏存档 → 默认）。
    static func load(defaults: UserDefaults = .standard) -> PlaybackControlSettings {
        PlaybackControlSettings.decode(defaults.string(forKey: defaultsKey))
    }

    /// 写入（先夹紧）。
    static func save(_ settings: PlaybackControlSettings, defaults: UserDefaults = .standard) {
        defaults.set(settings.persistenceValue, forKey: defaultsKey)
    }
}
