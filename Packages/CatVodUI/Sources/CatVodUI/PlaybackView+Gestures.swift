import CatVodPlayer
import Foundation
import SwiftUI

/// 播放页的手势（M27 起**三个内核共用**：系统内核的画面也换成了自建宿主，不再有「系统自带手势」这回事）。
///
/// 历史（M02P15 → M27）：系统内核原来用 `AVKit.VideoPlayer`，它自带一整套控件与手势 ——
/// 那时手势只挂在自绘内核（MPV / 自研 FFmpeg）上，叠到系统画面上只会互相打架
/// （「长按临时加速」当时就是因此没做，到 M03P12 才给自绘内核补上）；
/// M27 把系统内核的画面换成自建 `AVPlayerLayer` 宿主（``SystemVideoView``）之后，
/// 这里这套手势**三个内核都一样吃**。
///
/// | 手势 | 行为 |
/// | --- | --- |
/// | 双击 | 播放 / 暂停（**锁上之后不做**，见下） |
/// | 单击 | 显隐控制条（双击优先，M03P10） |
/// | 长按 | 临时加速，松手回到用户那份倍速（M03P12）；不在播不加速，但手势照样接管 |
/// | 横拖 | 调进度：拖动中只预览，**松手才 seek**（一次拖动几十个中间值，逐个 seek 会把内核打爆） |
/// | 双指捏合 | 缩放画面 1.0–5.0x（中心锚点），捏回 1.0 就是归位（M03P14） |
/// | 左半屏纵拖 | 调屏幕亮度：拖动中即时生效；拿不到亮度（macOS）则这次拖动不做事 |
/// | 右半屏纵拖 | 调音量：拖动中只看百分比，**松手下发内核** |
/// | 中间一半纵甩 | 切集：上滑下一集、下滑上一集（M03P23）；「是不是一甩」见 ``PlaybackSwipeRules`` |
///
/// **锁屏**（M03P21，`PlaybackView/isLocked`）：锁上之后双击、拖动、长按加速、捏合全停，
/// 只留单击 —— 锁上时控制条只剩解锁按钮，单击是把它叫回来的唯一办法（``LockedGesturePolicy``）。
///
/// **开关与动作归设置**（M28）：单击 / 双击各干什么、四条滑动开不开、震动要不要，都由
/// 「设置 → 播放器 → 播放控制」（``PlaybackControlSettings``）给 —— 三个内核同一份，
/// 播放页进页时读走（与「播放内核 / 解码方式」同一口径）。
///
/// **一甩切集**（M03P23，上游 `onFlingUp` / `onFlingDown`）：纵甩够长、够快、够直（见 ``PlaybackSwipeRules``）
/// 且起手在画面**中间一半** → 上滑下一集、下滑上一集；那一甩顺手调过的音量 / 亮度会**撤回去**
/// （不撤的话快速换集会一次跳掉小半格音量）。
///
/// 这次拖动调什么由**起点**决定（``DragMode``），开始那一刻定下就不再变 ——
/// 横向拖到一半拐弯也不会突然跳成调音量。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数顶到了 SwiftLint 的 `file_length` error（800）——
/// 拆文件不如拆职责：主文件留播放本体，手势独立成文件（与 `PlaybackView+Overlays` / `+Stats` 同一套做法）。
/// 跨文件的成员不能带 `private`：主文件里被这里用到的 `@State` 与两个方法因此改成了默认（internal）。
extension PlaybackView {
    /// 这次拖动在调什么。
    enum DragMode: Equatable {
        case seek
        /// 左半屏纵向：屏幕亮度。
        case brightness
        /// 右半屏纵向：App 内音量。
        case volume

        /// 日志里的名字（`PlaybackTrace` 用）。
        var title: String {
            switch self {
            case .seek: "进度"
            case .brightness: "亮度"
            case .volume: "音量"
            }
        }
    }

    /// 一次按住的账（M28 首验之十起）：只记**按下时刻** —— 加速什么时候起、尾巴吞不吞，
    /// 都按「从它量到点按那一刻」算。包成一个值、主文件里只留一个 `@State`
    /// （`PlaybackView` 的类型体行数顶在 lint 的 450 线上）。
    struct SpeedBoostPress: Equatable {
        var startedAt: Date
    }

    /// 换算常量：横向拖满一屏宽 ≈ 120 秒（M03P6）；纵向 200pt 走满量程（音量与亮度共用）。
    static let seekSecondsPerScreen: Double = 120
    static let verticalPointsForFullRange: Double = 200

    /// 按住多久**起加速**（手感线）。
    ///
    /// **0.4 秒**（M28 首验之十一按实测重定；此前 0.5 → 0.8 → 1.5 三次上调都建立在
    /// 「长按手势报的时刻」上，而那条路是坏的 —— 之十）。之十一的现场数据：真实单击
    /// **0.10–0.13 秒**（快速显隐控制条那种），「按实一点」的 0.45–0.66 秒 —— 0.4 秒这条线
    /// 离单击有三倍余量，同时接得住用户那半秒出头的「长按」手感。
    static let speedBoostHoldSeconds: Double = 0.4
    /// 量出来的按住 ≥ 它，**尾巴点按才吞**（防误吞线）。
    ///
    /// 比手感线高一截（0.8）：宁可「长按完控制条跳一下」，也不误吞一根真点按 ——
    /// 「点屏幕没反应 / 按钮点了没动静」是用户最不能忍的一类（之十的日志就是被吞出来的）。
    static let speedBoostSwallowHoldSeconds: Double = 0.8
    /// 「按下」怎么拿到：挂一条**门槛几乎为零**的长按，它一成立（≈ 按下的那一刻）就是报时器。
    /// 起加速的门槛由我们自己的计时走（见 ``speedBoostHoldSeconds``）—— 不再借它的识别时机，
    /// **也不串零距离拖动**（之十一：串出来的拖动会把画面那条拖动整条按死，滑动全没了）。
    static let speedBoostPressDetectSeconds: Double = 0.01
    /// 按住期间允许的抖动（超过这个距离就不算长按，交给拖动那条）。
    static let speedBoostMaxDistance: CGFloat = 10

    /// 双指缩放的上限（上游 `Math.clamp(scale, 1.0f, 5.0f)` 里的那个 5）。
    static let zoomMaximum: CGFloat = 5

    // MARK: - 判定与换算（纯函数，有单测）

    /// 「判方向」的清晰度门限：主轴至少是次轴的这么多倍才算看清楚（M28 首验之九）。
    ///
    /// 为什么不是「第一帧就定」：`DragGesture(minimumDistance: 24)` 的第一帧是手指已经走了 24pt
    /// 才报的，而「起手慢的滑动」（快进 / 快退常常是先按住、再起步）第一帧往往还带着明显的纵向分量 ——
    /// 一帧定死会把「快进 / 快退」误判成调亮度 / 音量，而且定下就不再变（用户报
    /// 「滑动的快退和快进有 bug」）。够清楚才定；**定下之后不再变**（横拖到一半拐弯也不会跳成
    /// 调音量 —— M03P12 那条规矩不变）。
    static let dragModeClarityRatio: CGFloat = 1.25

    /// 这次拖动调什么（**纯函数**，有单测）：横向主导 → 进度；纵向主导 → 按起点分左右半屏
    /// （左亮度 / 右音量，中线算右半屏）；`nil` = 这一帧还看不清（下一个 `onChanged` 再看）。
    static func dragMode(dx: CGFloat, dy: CGFloat, startX: CGFloat, width: CGFloat) -> DragMode? {
        let horizontal = abs(dx)
        let vertical = abs(dy)
        if horizontal >= vertical * dragModeClarityRatio {
            return .seek
        }
        if vertical >= horizontal * dragModeClarityRatio {
            return startX < width / 2 ? .brightness : .volume
        }
        return nil
    }

    /// 横向拖了多少 → 目标秒数（夹在 0...总时长）。
    static func seekTarget(base: Double, dx: CGFloat, width: CGFloat, duration: Double) -> Double {
        let delta = Double(dx / max(width, 1)) * seekSecondsPerScreen
        return min(max(base + delta, 0), max(duration, 0))
    }

    /// 纵向拖了多少 → 目标值：向上加、向下减，`pointsForFullRange` pt 走满量程，结果夹在 0...1。
    static func verticalValue(base: Double, dy: CGFloat, pointsForFullRange: Double) -> Double {
        min(max(base - Double(dy) / pointsForFullRange, 0), 1)
    }

    /// 长按加速能不能开始（纯函数，有单测）：上游同款守卫 —— 不在播就按了也白按。
    static func canStartSpeedBoost(isPlaying: Bool, isBoosting: Bool) -> Bool {
        isPlaying && !isBoosting
    }

    /// 双指捏合换出的倍数（纯函数，有单测）：夹在 1.0 ... ``zoomMaximum`` —— 捏回 1.0 就是归位。
    static func zoomValue(base: CGFloat, magnification: CGFloat) -> CGFloat {
        min(max(base * magnification, 1), zoomMaximum)
    }

    // MARK: - 画面外壳

    /// 自绘内核画面的共同外壳：单击 / 双击 / 长按 / 拖动全在这一层 —— 但**只有一条手势**（M28 首验之十二）。
    ///
    /// 点按 / 双击的优先级、落点、长按加速、拖动，全在 ``touchGesture`` 那一条里自己算 ——
    /// 不再叠 `SpatialTapGesture` / `LongPressGesture`：只要视频层上有一条「成功」的长按，
    /// 画面那条拖动就被整个按死（滑动没反应；之十、十一、十二三次首验都是它）。
    func interactiveLayer(_ content: some View, size: CGSize) -> some View {
        content
            // 缩放只作用在画面上（弹幕 / 字幕 / 控制条不跟着放大）：先缩放、再裁切，
            // 手势挂在**没被缩放的**那一层上 —— 拖动距离仍然按屏幕距离算。
            .scaleEffect(zoomScale)
            .clipped()
            .contentShape(Rectangle())
            .gesture(touchGesture(width: size.width))
            // 双指缩放（M03P14）：版本分支在基础件里（`Platform/AdaptiveZoom.swift`）——
            // 业务视图不写 `#available`（`docs/UI 规范.md` 第二节）。
            .adaptiveMagnificationGesture(
                onChanged: { magnification in applyZoom(magnification: magnification) },
                onEnded: { finishZoom() }
            )
    }

    // MARK: - 一甩切集（M03P23）

    /// 这次松手算不算一甩：视图上的量递给纯规则（``PlaybackSwipeRules``）。
    static func swipeAction(value: DragGesture.Value, speed: Double, width: CGFloat) -> PlaybackSwipeAction? {
        PlaybackSwipeRules.action(
            translation: value.translation,
            speed: speed,
            startX: value.startLocation.x,
            width: width
        )
    }

    /// 撤掉这次拖动里已经做出的音量 / 亮度调整（一甩切集时用）。
    ///
    /// 为什么撤：一甩的位移是「切集的手势」，不是「调音量」—— 顺手把音量调掉小半格不是用户要的。
    func revertGestureAdjustment() {
        if gestureDrag == .volume, let base = gestureBaseVolume {
            volume = base
        } else if gestureDrag == .brightness, let base = gestureBaseBrightness {
            PlatformShims.setScreenBrightness(base)
        }
    }

    /// 拖动收尾：基准 / 这次在调什么 / 提示一起清掉（提示随后由切集流程或下一次手势再写）。
    func settleGesture() {
        gestureBasePosition = nil
        gestureBaseVolume = nil
        gestureBaseBrightness = nil
        gestureDrag = nil
        gestureHint = ""
    }

    /// 一甩要干的事：点播页换集（上游 `onFlingUp` / `onFlingDown`）、直播页换台（M07d10）。
    ///
    /// - 点播（有 `playlist`）：上滑下一集、下滑上一集；到头了直说一句（上游是回头重刷一遍，
    ///   我们这儿说不出那还能干嘛，不如直说），提示过一会儿自己收；换集期间提示留在屏上
    ///   （找地址 / 起播要一会儿），换完（或失败）再清 —— 新画面 / 错误行就是反馈；
    /// - 直播（有 `onVerticalSwipe`）：**方向的含义由宿主决定**（上游 `LiveActivity` 默认
    ///   上滑 = 上一台，`LiveSetting.isInvert()` 在那一层翻），这里只把「上 / 下」报上去；
    /// - 两样都没有的入口不会走到这儿（判定那一步就把甩挡掉了）。
    func performSwipe(_ swipe: PlaybackSwipeAction) async {
        guard let playlist, let current = currentEpisodeIndex else {
            onVerticalSwipe?(swipe)
            return
        }
        let target = swipe == .up
            ? playlist.nextIndex(after: current)
            : playlist.previousIndex(before: current)
        guard let target else {
            let text = swipe == .up ? "已经是最后一集" : "已经是第一集"
            gestureHint = text
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if gestureHint == text {
                gestureHint = ""
            }
            return
        }
        gestureHint = "\(swipe == .up ? "下一集" : "上一集")：\(playlist.episodeName(at: target))"
        await switchEpisode(to: target)
        gestureHint = ""
    }

    // MARK: - 点按分区（M28）

    /// 一次点按该干什么：动作从设置取（``PlaybackControlSettings/tapAction``），
    /// 分区判定**复用「纵甩切集」那条**（中间一半 = 中间，两侧四分之一 = 两边）——
    /// 手上不按屏幕分区，规则就必须是同一份。
    ///
    /// `location`：点按的落点（iOS 16+ 由 `SpatialTapGesture` 给；iOS 15 那条路给 nil，
    /// 按「中间」处理）。`held` 只进日志（这次点按距长按起多久）。
    func handleTap(doubleTap: Bool, at location: CGPoint?, width: CGFloat, held: TimeInterval? = nil) {
        let startX = location?.x
        let isCenter = Self.isCenterTap(startX: startX, width: width)
        let action = controlSettings.tapAction(doubleTap: doubleTap, isCenter: isCenter)
        PlaybackTrace.noteTap(
            doubleTap: doubleTap,
            location: location,
            isCenter: isCenter,
            action: action.title,
            held: held
        )
        switch action {
        case .toggleControls:
            toggleControlsVisibility()
        case .playPause:
            Task { await togglePlayback() }
        case .seek:
            // 左退右进：与「快退 / 快进」的排法一致。
            let backwards = (startX ?? width / 2) < width / 2
            Task { await seekBy(seconds: backwards ? -controlSettings.seekStepSeconds : controlSettings.seekStepSeconds) }
        case .none:
            break
        }
    }

    /// 落点算不算「中间一半」（**纯函数**，有单测）：拿不到落点时按中间算 —— 中间那一档是主档。
    static func isCenterTap(startX: CGFloat?, width: CGFloat) -> Bool {
        guard let startX else {
            return true
        }
        return PlaybackSwipeRules.isCenterZone(startX: startX, width: width)
    }

    /// 这次拖动调的东西是不是开着（**纯函数**，有单测）：关掉的手势整次不做事。
    static func dragEnabled(_ mode: DragMode, settings: PlaybackControlSettings) -> Bool {
        switch mode {
        case .seek: settings.swipeSeek
        case .brightness: settings.swipeBrightness
        case .volume: settings.swipeVolume
        }
    }

    /// 快进 / 快退（双击分区选了「快进 / 快退」时用）：夹在 0...时长，提示留一会儿自己收。
    func seekBy(seconds: Double) async {
        let target = min(max(latestPosition + seconds, 0), max(latestDuration, 0))
        let hint = "\(seconds >= 0 ? "快进" : "快退") → \(Self.timeText(target))"
        gestureHint = hint
        await engine?.seek(to: target)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        if gestureHint == hint {
            gestureHint = ""
        }
    }

    // MARK: - 双指缩放

    /// 捏合过程中的倍数：两种 API 的入口都走这里（基准值进一次、后面都按它乘）。
    private func applyZoom(magnification: CGFloat) {
        // 锁上之后捏合也不缩放（M03P21；上游 `onScaleBegin` 里 checks 了 lock）。
        guard !isLocked else {
            return
        }
        isZooming = true
        let base = gestureBaseZoom ?? zoomScale
        gestureBaseZoom = base
        zoomScale = Self.zoomValue(base: base, magnification: magnification)
        gestureHint = "缩放 \(String(format: "%.1f", zoomScale))x"
    }

    /// 捏合结束：清基准与提示；**倍数留在原地**（捏回 1.0 就是用户自己要归位）。
    private func finishZoom() {
        isZooming = false
        gestureBaseZoom = nil
        gestureHint = ""
    }

    // MARK: - 长按加速（M03P12；计时与分档从 M28 首验之十起都自己量）

    /// 手指按下了（`PlaybackView+Touch.swift` 的触摸首帧报到；≈ 真实按下的那一刻）：记下起点，
    /// 把「按住够 ``speedBoostHoldSeconds`` 秒 → 起加速」的计时排上。
    ///
    /// 上一次的加速要是还挂着（它的松手丢了），先当场收干净 —— 不能再让新的按住接着挂。
    func beginSpeedBoostPress() {
        guard !isLocked else {
            return
        }
        if isSpeedBoostHolding {
            endSpeedBoost(reason: "上一次没收到松手")
        }
        speedBoostPress = SpeedBoostPress(startedAt: Date())
        speedBoostArmTask?.cancel()
        speedBoostArmTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.speedBoostHoldSeconds * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            beginSpeedBoost()
        }
    }

    /// 按住够 ``speedBoostHoldSeconds``（``speedBoostArmTask`` 走到的）：真把速度切过去。
    ///
    /// 守卫与上游同款：不在播不切（但「按住」这件事照样成立 —— 尾点按的吞 / 放判定不受它影响）；
    /// 锁上、或已经挂着一次没收到松手的加速，都不再来一遍。
    /// 提示直接用倍速文本（`2.0x`，上游 `play_speed_hint` 同款），按住期间一直亮着；
    /// 加速到多少是**可调的**（M03P13：播放页「长按倍速」，上游 `speed_long_press`）。
    func beginSpeedBoost() {
        // 锁上之后长按不加速（M03P21）—— 上游 `onLongPress` 里就是这一条早退。
        guard !isSpeedBoostHolding, !isLocked, speedBoostPress != nil else {
            return
        }
        isSpeedBoostHolding = true
        // 按住期间**别让控制条动**（上游同款：控制条一显一隐是一次视图树结构变化，容易把正在跑的
        // 手势搅乱）；加速收掉时 `endSpeedBoost()` 按当前状态补排一次（见 `refreshControlsForState()`）。
        controlsHideTask?.cancel()
        controlsHideTask = nil
        guard Self.canStartSpeedBoost(isPlaying: playerState.isPlaying, isBoosting: isSpeedBoosting), let engine else {
            // 到点了但没起（多半是暂停着）：留一条，别让「长按没反应」没有落点可查。
            PlaybackTrace.noteBoost("按住到点，没起（不在播 / 没内核）")
            return
        }
        isSpeedBoosting = true
        gestureHint = SpeedSetting.format(longPressSpeed)
        PlaybackTrace.noteBoost("起 \(SpeedSetting.format(longPressSpeed))")
        if controlSettings.hapticLongPress {
            PlaybackHaptics.press()
        }
        let boost = longPressSpeed
        Task { await engine.setRate(boost) }
    }

    /// 松手 / 拖动 / 布局变化 / 退到后台：把加速收掉，回到**用户那份**倍速
    /// （他把速度设成 1.5x 时按一下不该变成 1.0x）；本来就没加速（不在播 / 没内核）
    /// 就只是把长按状态收掉。计时的撤销在这儿**统一**做：不管有没有真起加速，
    /// 这一刻的「按住」都已经不算数了。
    ///
    /// `reason` 只进日志 —— 排障时要能分清是「松手」「自愈」还是「布局变了」。
    func endSpeedBoost(reason: String = "松手") {
        speedBoostArmTask?.cancel()
        speedBoostArmTask = nil
        guard isSpeedBoostHolding else {
            return
        }
        isSpeedBoostHolding = false
        gestureHint = ""
        PlaybackTrace.noteBoost("收（\(reason)）")
        if isSpeedBoosting {
            isSpeedBoosting = false
            setSpeed(speed, persist: false)
        }
        // 按住期间控制条没动过（见 `beginSpeedBoost()`）：松手后按当前状态补排一次。
        refreshControlsForState()
    }

    /// 「这一按到此为止」的整条收尾（拖动接手 / 布局变化 / 退到后台用）：
    /// 收加速 + 撤掉计时 + 把按住的账结清 —— 三件事永远一起做，别各写一份。
    func finishSpeedBoostSession(reason: String) {
        endSpeedBoost(reason: reason)
        consumePressSession()
    }

    /// 点按该当何论。
    enum TapDisposition: Equatable {
        /// 真·长按（量的按住时长 ≥ ``speedBoostSwallowHoldSeconds``）的尾巴：吞掉。
        case swallow
        /// 正常点按（含「按得实一点的单击」）：放行。
        case allow
        /// 「还按着」但连按下时刻都没有（状态坏了 / 上一次长按挂了）：先收掉加速，再放行。
        case endStaleBoost
    }

    /// 这次点按归哪一类（**纯函数**，有单测）：只看**松手那一刻量到的按住时长**。
    ///
    /// - 按住 ≥ ``speedBoostSwallowHoldSeconds``：真·长按的尾巴 —— 吞（不让控制条闪）；
    /// - 短于它（含「按得实一点的单击」）：放行 —— 现场日志里 0.45 秒的单击被吞过，
    ///   正是「点屏幕没反应 / 按钮点了没动静」里最难受的一种；
    /// - 连按住时长都没量到：还按着当挂死（自愈 + 放行），没按着直接放行。
    static func tapDisposition(
        isHolding: Bool,
        heldSeconds: TimeInterval?
    ) -> TapDisposition {
        if let heldSeconds {
            return heldSeconds >= speedBoostSwallowHoldSeconds ? .swallow : .allow
        }
        return isHolding ? .endStaleBoost : .allow
    }

    /// 这次按住量出来的时长（秒）；没记到按下时刻给 nil。
    ///
    /// **只进日志与分档判定**（松手那一刻调用）—— 「吞 / 放」的输入就是它，排障不用再猜。
    var currentPressSeconds: TimeInterval? {
        guard let press = speedBoostPress else {
            return nil
        }
        return Date().timeIntervalSince(press.startedAt)
    }

    /// 这次点按要不要吞掉（判定见 ``tapDisposition(isHolding:heldSeconds:)``）。
    ///
    /// `held` = 松手那一刻量到的按住时长（等双击窗口那 0.35 秒不算进来）。
    /// 不管哪一档，走到这儿都要做两件事：
    /// 1. **撤掉「按住计时」** —— 别让计时再把加速点着（正常路径在松手时已撤，这里兜底）；
    /// 2. **把这次按住的账清掉**（`consumePressSession`）—— 那一下就是尾巴本身，
    ///    别再让它吞掉下一个真点按；
    /// 3. **加速再收一次**（`endSpeedBoost`，没起过 / 已收过都是空操作）—— 保底。
    func shouldSwallowTap(held: TimeInterval?) -> Bool {
        let disposition = Self.tapDisposition(
            isHolding: isSpeedBoostHolding,
            heldSeconds: held
        )
        speedBoostArmTask?.cancel()
        speedBoostArmTask = nil
        switch disposition {
        case .swallow:
            // 只有控制条**亮着**时才吞（吞的目的是别让它闪一下）；暗着的时候这一下照常执行 ——
            // 用户按屏幕十有八九就是要把它叫出来（M28 首验之六：控制条暗着时怎么按都不出来，
            // 是「点屏幕没反应」里最难受的一种）。
            if isControlsVisible {
                endSpeedBoost(reason: "尾巴（真·长按）")
                consumePressSession()
                return true
            }
            endSpeedBoost(reason: "尾巴（控制条暗着，放行）")
            consumePressSession()
            return false
        case .allow:
            endSpeedBoost(reason: "松手（按得短，放行）")
            consumePressSession()
            return false
        case .endStaleBoost:
            endSpeedBoost(reason: "自愈（挂太久）")
            consumePressSession()
            return false
        }
    }

    /// 这次按住的账（按下时刻）到此为止：尾巴点按只吞它自己那一下；
    /// 拖动 / 布局变化 / 退到后台这类「不会再有尾巴点按」的路径也顺手结清。
    func consumePressSession() {
        speedBoostPress = nil
    }
}
