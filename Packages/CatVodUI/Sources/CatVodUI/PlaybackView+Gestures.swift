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

    /// 一次按住的账（M28 首验之十）：按下 / 松手两个时刻 —— 加速起不收、尾巴吞不吞都按它算。
    /// 包成一个值、主文件里只留一个 `@State`：`PlaybackView` 的类型体行数顶在 lint 的 450 线上。
    struct SpeedBoostPress: Equatable {
        var startedAt: Date
        var endedAt: Date?
    }

    /// 换算常量：横向拖满一屏宽 ≈ 120 秒（M03P6）；纵向 200pt 走满量程（音量与亮度共用）。
    static let seekSecondsPerScreen: Double = 120
    static let verticalPointsForFullRange: Double = 200

    /// 按住多久算「真·长按」。
    ///
    /// **1.5 秒**（M28 首验之八定的这条线）。这条线现在管两件事，都用**量出来的按住时长**算：
    /// 按住够 1.5 秒才起加速；松手后按住时长 ≥ 1.5 秒才吞尾巴。
    ///
    /// 为什么时刻要自己量（M28 首验之十）：现场日志里「距长按起 0.45s」的单击也起过加速、
    /// 还整条被吞 —— 长按手势报「成立」的时机与真实按住时长对不上（0.5 → 0.8 → 1.5 三次上调
    /// 都躲不开它，因为问题不在线的高低）。现在「按下」由一条 0.01 秒的长按报时
    /// （``speedBoostPressDetectSeconds``），这条线由 ``speedBoostArmTask`` 自己走。
    static let speedBoostHoldSeconds: Double = 1.5
    /// 「按下」怎么拿到：挂一条**门槛几乎为零**的长按，它一成立（≈ 按下的那一刻）就是报时器。
    /// 真·长按的门槛由我们自己的计时走（见 ``speedBoostHoldSeconds``）—— 不再借它的识别时机。
    static let speedBoostPressDetectSeconds: Double = 0.01
    /// 按住期间允许的抖动（超过这个距离就不算长按，交给拖动那条）。
    /// 与 `LongPressGesture` 的 `maximumDistance` 同一条线；按住期间的持续检查见 ``pressMoved(_:)``。
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

    /// 按住期间「动了」没有（**纯函数**，有单测）：任一方向超过 ``speedBoostMaxDistance`` 就不算按住。
    ///
    /// 与 `LongPressGesture` 的 `maximumDistance` 同一条线 —— 但那条只管「识别成功之前」，
    /// 现在识别几乎瞬间成立（0.01 秒），「动没动」得在按住期间一直盯着（见 `speedBoostGesture`）。
    static func pressMoved(_ translation: CGSize) -> Bool {
        abs(translation.width) > speedBoostMaxDistance || abs(translation.height) > speedBoostMaxDistance
    }

    /// 双指捏合换出的倍数（纯函数，有单测）：夹在 1.0 ... ``zoomMaximum`` —— 捏回 1.0 就是归位。
    static func zoomValue(base: CGFloat, magnification: CGFloat) -> CGFloat {
        min(max(base * magnification, 1), zoomMaximum)
    }

    // MARK: - 画面外壳

    /// 自绘内核画面的共同外壳：单击 / 双击 / 长按 / 拖动全在这一层。
    ///
    /// **单击 / 双击的优先级**（M03P10）：`exclusively(before:)` 让双击先决 —— 单击只在
    /// 「没有第二下」之后才触发，所以双击播放时控制条不会先闪一下。
    func interactiveLayer(_ content: some View, size: CGSize) -> some View {
        content
            // 缩放只作用在画面上（弹幕 / 字幕 / 控制条不跟着放大）：先缩放、再裁切，
            // 手势挂在**没被缩放的**那一层上 —— 拖动距离仍然按屏幕距离算。
            .scaleEffect(zoomScale)
            .clipped()
            .contentShape(Rectangle())
            // 点按（双击优先）+ **落点**：版本分支在基础件里（`Platform/AdaptiveTap.swift`）——
            // iOS 16+ 是 `SpatialTapGesture`（有落点），iOS 15 回落 `TapGesture`（落点 nil，
            // 按「中间」那一档处理）。**不要**为了记落点另挂「旁听」手势：首验踩过 —— 零距离拖动
            // 照样进手势竞争，点按被吃掉、长按加速被挂死（点屏幕没反应 + `2.0x` 常亮）。
            .adaptiveTapGesture(
                onDoubleTap: { location in
                    // 双击干什么由设置给（M28）；锁上之后不做（M03P21，上游 onDoubleTap 同款早退）。
                    let unlocked = Self.lockedGesturePolicy(isLocked: isLocked) == .all
                    let held = currentPressSeconds
                    guard unlocked, !shouldSwallowTap() else {
                        // 没做事的那些也留一条痕（「哪一段断了」全在日志里，排障不靠猜）。
                        let skipped: String = unlocked ? "（被长按尾巴吞掉）" : "（锁上不做）"
                        PlaybackTrace.noteTap(
                            doubleTap: true,
                            location: location,
                            isCenter: Self.isCenterTap(startX: location?.x, width: size.width),
                            action: skipped,
                            held: held
                        )
                        return
                    }
                    handleTap(doubleTap: true, at: location, width: size.width, held: held)
                },
                onSingleTap: { location in
                    let held = currentPressSeconds
                    guard !shouldSwallowTap() else {
                        PlaybackTrace.noteTap(
                            doubleTap: false,
                            location: location,
                            isCenter: Self.isCenterTap(startX: location?.x, width: size.width),
                            action: "（被长按尾巴吞掉）",
                            held: held
                        )
                        return
                    }
                    handleTap(doubleTap: false, at: location, width: size.width, held: held)
                }
            )
            // 长按加速与点按**同时**识别：不用 `exclusively`，那会把正常单击也一起赔进去；
            // 长按松手后补发的那次点按由 `shouldSwallowTap()` 吞掉（见它的说明）。
            .simultaneousGesture(speedBoostGesture)
            .gesture(playerGesture(width: size.width))
            // 双指缩放（M03P14）：版本分支在基础件里（`Platform/AdaptiveZoom.swift`）——
            // 业务视图不写 `#available`（`docs/UI 规范.md` 第二节）。
            .adaptiveMagnificationGesture(
                onChanged: { magnification in applyZoom(magnification: magnification) },
                onEnded: { finishZoom() }
            )
    }

    /// 长按临时加速（M03P12）：按住画面 → 换成长按倍速；松手 → 回到用户那份倍速。
    ///
    /// **两件事分开（M28 首验之十）**：
    /// 1. 「按下」由一条门槛几乎为零的长按（``speedBoostPressDetectSeconds`` = 0.01 秒）报时 ——
    ///    它一成立 ≈ 按下的那一刻；
    /// 2. 「按住够 1.5 秒 → 起加速」由自己的 ``speedBoostArmTask`` 计时，松手 / 动了 / 布局变了都撤。
    ///
    /// 为什么不再让长按手势自己担 1.5 秒：之十的现场日志里，0.45 秒的单击也起了加速、
    /// 尾巴还把整条单击吞了 —— 手势报「成立」的时机与真实按住时长对不上（线从 0.8 提到 1.5 也没用）。
    /// 自己计时之后，「起加速」与「吞尾巴」都只认**量出来的按住时长**。
    ///
    /// 为什么还串一个零距离拖动：长按手势的 `onEnded` 在**识别成功**时就发，拿不到「松手」；
    /// 串完整个序列跟着手指结束，`onEnded` 才是松手（按下与松手两个时刻就都拿全了）。
    private var speedBoostGesture: some Gesture {
        LongPressGesture(
            minimumDuration: Self.speedBoostPressDetectSeconds,
            maximumDistance: Self.speedBoostMaxDistance
        )
        .sequenced(before: DragGesture(minimumDistance: 0))
        .onChanged { value in
            switch value {
            case .first(true):
                beginSpeedBoostPress()
            case let .second(true, drag):
                // 长按手势没把「成立」报到（版本差异）时的兜底：第一次拖动事件里补上按下时刻。
                if speedBoostPress == nil {
                    beginSpeedBoostPress()
                }
                // 动了（超过抖动线）就不是「按住」：把这一按整条撤掉（没起的计时、起了的加速）。
                if let drag, Self.pressMoved(drag.translation) {
                    endSpeedBoost(reason: "动了（不是按住加速）")
                }
            default:
                break
            }
        }
        .onEnded { _ in endSpeedBoostPress() }
    }

    /// 拖动：进度 / 亮度 / 音量三选一。加速期间与捏合期间整条拖动不做事
    /// （上游同款：`changeSpeed` 时 `onScroll` 直接 return —— 按住加速的手指抖一下不该变成拖进度；
    /// 捏合时也是，两根手指本来就不是在拖）。
    private func playerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                // 手已经在拖了（≥24pt）：这次触摸**不是**「按住加速」—— 立刻把加速（或还没点着的
                // 计时）收掉、放行这次拖动。
                //
                // 为什么不能等信任窗（首验之七 · 用户报「滑动快进快退和倍速好像连着了」）：
                // 长按手势的 `maximumDistance` **只管「识别之前」那一段** —— 长按一旦成立，
                // 手指之后再滑多远都不算失败。于是「起手慢一点的滑动」（快进 / 快退要先按住再看方向）
                // 会先被判成长按、视频上到 2.0x，而后面的拖动还要等 1.3 秒才被放行 ——
                // 用户看到的就是「一滑就 2 倍速、拖动前 1.3 秒没反应」。
                // 现在起加速是自己的计时（M28 首验之十）：拖动一开始就把「按住」这条账整条销掉。
                if isSpeedBoostHolding || speedBoostPress != nil {
                    finishSpeedBoostSession(reason: "开始拖动（不是按住加速）")
                }
                guard !isZooming, !isLocked else {
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height
                let mode: DragMode
                if let latched = gestureDrag {
                    mode = latched
                } else if let decided = Self.dragMode(dx: dx, dy: dy, startX: value.startLocation.x, width: width) {
                    // 方向够清楚了：定下这次拖动调什么（定下就不再变），顺手清掉上一轮的采样
                    // （上一轮可能被长按 / 捏合打断，没走到收尾）。
                    mode = decided
                    gestureDrag = decided
                    gestureSwipe.reset()
                    // 数字先落成局部量再拼：嵌套插值塞给类型检查器不划算（吃过一次亏）。
                    let dxText = Int(dx.rounded())
                    let dyText = Int(dy.rounded())
                    PlaybackTrace.noteDrag("起：" + decided.title + "（dx=" + String(dxText) + " dy=" + String(dyText) + "）")
                } else {
                    // 还看不清方向（第一帧带着明显的纵向抖动）：这一帧不做事、也先不记采样 ——
                    // 免得把抖动记成「一甩」（M28 首验之九）。
                    return
                }
                // 纵甩切集的采样（M03P23）：判不判得成甩在松手那一刻算（见 ``PlaybackSwipeRules``）。
                gestureSwipe.record(at: Date().timeIntervalSinceReferenceDate, y: Double(dy))
                // 设置里关掉的手势：整次拖动不做事（不提示、不改值）—— 采样照记，
                // 因为「短剧滑动切集」是**另一项**开关（判在松手那一刻，见 `onEnded`）。
                guard Self.dragEnabled(mode, settings: controlSettings) else {
                    return
                }
                switch mode {
                case .seek:
                    // 时长还没读到（起播头几秒 / 直播）：**不拖** —— 没有可夹的范围，硬拖会把目标
                    // 夹成 0，一松手就跳回开头。给一句直说，不摆「拖了没反应」的假手势。
                    guard latestDuration > 0 else {
                        gestureHint = "时长还没读到，先等等"
                        return
                    }
                    let base = gestureBasePosition ?? latestPosition
                    gestureBasePosition = base
                    let target = Self.seekTarget(base: base, dx: dx, width: width, duration: latestDuration)
                    if controlSettings.hapticSeek, hapticGates.shouldTickSeek(target) {
                        PlaybackHaptics.tick()
                    }
                    gestureHint = "\(Self.timeText(target)) / \(Self.timeText(latestDuration))"
                case .brightness:
                    // 拿不到亮度（macOS 没有公开 API）就整次拖动不做事 —— 不摆一个「拖了没反应」的假手势。
                    guard let base = gestureBaseBrightness ?? PlatformShims.screenBrightness() else {
                        return
                    }
                    gestureBaseBrightness = base
                    let target = Self.verticalValue(base: base, dy: dy, pointsForFullRange: Self.verticalPointsForFullRange)
                    PlatformShims.setScreenBrightness(target)
                    if controlSettings.hapticBrightness, hapticGates.shouldTickBrightness(target) {
                        PlaybackHaptics.tick()
                    }
                    gestureHint = "亮度 \(Int((target * 100).rounded()))%"
                case .volume:
                    let base = gestureBaseVolume ?? volume
                    gestureBaseVolume = base
                    volume = Self.verticalValue(base: base, dy: dy, pointsForFullRange: Self.verticalPointsForFullRange)
                    if controlSettings.hapticVolume, hapticGates.shouldTickVolume(volume) {
                        PlaybackHaptics.tick()
                    }
                    gestureHint = "音量 \(Int((volume * 100).rounded()))%"
                }
            }
            .onEnded { value in
                guard !isZooming, !isLocked else {
                    // 这次拖动被打断（捏合 / 锁）：把这次的临时状态收掉 ——
                    // 提示条现在是「常挂只翻透明度」，不清的话那句「亮度 50%」会一直挂在屏上。
                    settleGesture()
                    return
                }
                // 纵甩（M03P23 起；M07d10 起直播页也吃它）：先判甩 —— 甩了就撤掉这次顺手做的
                // 音量 / 亮度调整，seek / 下发音量那两条路都不走。
                // **有得可换才判**：点播页要 `playlist`（换集），直播页要 `onVerticalSwipe`（换台）；
                // 两样都没有的页面（下载播放 / 设置页试播）纵甩还是音量 / 亮度（不然甩一下会白撤一次调整）。
                let canVerticalSwipe = (playlist != nil && controlSettings.swipeEpisode) || onVerticalSwipe != nil
                let speed = gestureSwipe.speed(at: Date().timeIntervalSinceReferenceDate)
                gestureSwipe.reset()
                let swipe: PlaybackSwipeAction? = canVerticalSwipe
                    ? Self.swipeAction(value: value, speed: speed, width: width)
                    : nil
                if let swipe {
                    revertGestureAdjustment()
                    settleGesture()
                    PlaybackTrace.noteDrag("收：纵甩（\(swipe == .up ? "上" : "下")）")
                    Task { await performSwipe(swipe) }
                    return
                }
                if let mode = gestureDrag, Self.dragEnabled(mode, settings: controlSettings) {
                    if mode == .seek, let base = gestureBasePosition, latestDuration > 0 {
                        // 进度：松手才 seek。
                        let target = Self.seekTarget(base: base, dx: value.translation.width, width: width, duration: latestDuration)
                        PlaybackTrace.noteDrag("收：进度 → \(Self.timeText(target))（松手交给内核）")
                        Task { await engine?.seek(to: target) }
                    } else if mode == .volume, gestureBaseVolume != nil {
                        // 音量：松手才下发内核；亮度那边拖动中已经写进系统亮度了，这里没它的事。
                        let target = Float(volume)
                        PlaybackTrace.noteDrag("收：音量 \(Int((target * 100).rounded()))%（松手交给内核）")
                        Task { await engine?.setVolume(target) }
                    } else if mode == .brightness {
                        // 亮度在拖动中已经写进系统亮度了，这里只留一条痕。
                        PlaybackTrace.noteDrag("收：亮度（拖动中已写入系统亮度）")
                    }
                }
                settleGesture()
            }
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

    /// 手指按下了（`speedBoostGesture` 报到；≈ 真实按下的那一刻）：记下起点，
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

    /// 松手（长按序列的 `onEnded`）：记下松手时刻（「松手先被识别」那条路的尾巴点按随后到，
    /// 按住时长 = 松手 − 按下），并把加速收掉。挂着的尾巴点按由 `shouldSwallowTap()` 分档。
    func endSpeedBoostPress() {
        speedBoostPress?.endedAt = Date()
        endSpeedBoost(reason: "松手")
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
        // 按住期间**别让控制条动**：它一显一隐就是一次视图树结构变化，而结构变化会把这次长按
        // 序列取消 —— 松手就再也不会来（提示常亮 2.0x、点按被吞）。松手时 `endSpeedBoost()`
        // 按当前状态补排一次（见 `refreshControlsForState()`）。
        controlsHideTask?.cancel()
        controlsHideTask = nil
        guard Self.canStartSpeedBoost(isPlaying: playerState.isPlaying, isBoosting: isSpeedBoosting), let engine else {
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
        /// 真·长按（量的按住时长 ≥ ``speedBoostHoldSeconds``）的尾巴：吞掉。
        case swallow
        /// 正常点按（含「按得实一点的单击」）：放行。
        case allow
        /// 「还按着」但连按下时刻都没有（状态坏了 / 上一次长按挂了）：先收掉加速，再放行。
        case endStaleBoost
    }

    /// 这次点按归哪一类（**纯函数**，有单测）：只看**量出来的按住时长**。
    ///
    /// - 按住 ≥ ``speedBoostHoldSeconds``：真·长按的尾巴 —— 吞（不让控制条闪）；
    /// - 短于它（含「按得实一点的单击」）：放行 —— 之十现场日志里 0.45 秒的单击被吞过，
    ///   正是「点屏幕没反应 / 按钮点了没动静」里最难受的一种；
    /// - 连按下时刻都没记到：还按着当挂死（自愈 + 放行），没按着直接放行。
    ///
    /// 两条来信都认：尾巴点按先到（`pressEndedAt` 还是 nil，用 `now` 顶上）与松手先到
    /// （`onEnded` 已记下松手时刻）—— 顺序不固定（日志实测两个方向都出现过），
    /// 所以两种都按同一本账量。
    static func tapDisposition(
        isHolding: Bool,
        pressStartedAt: Date?,
        pressEndedAt: Date?,
        now: Date
    ) -> TapDisposition {
        if let started = pressStartedAt {
            let ended = pressEndedAt ?? now
            return ended.timeIntervalSince(started) >= speedBoostHoldSeconds ? .swallow : .allow
        }
        return isHolding ? .endStaleBoost : .allow
    }

    /// 这次按住量出来的时长（秒）；没记到按下时刻给 nil。
    ///
    /// **只进日志与分档判定** —— 「吞 / 放」的输入就是它，排障时不用再猜用户按了多久。
    var currentPressSeconds: TimeInterval? {
        guard let press = speedBoostPress else {
            return nil
        }
        return (press.endedAt ?? Date()).timeIntervalSince(press.startedAt)
    }

    /// 这次点按要不要吞掉（判定见 ``tapDisposition(isHolding:pressStartedAt:pressEndedAt:now:)``）。
    ///
    /// 不管哪一档，走到这儿都要做两件事：
    /// 1. **撤掉「按住计时」** —— 点按只在松手后才来，这一按到此为止，别让计时再把加速点着；
    /// 2. **把这次按住的账清掉**（`consumePressSession`）—— 那一下就是尾巴本身，
    ///    别再让它吞掉下一个真点按（吞的那条顺手把加速收掉：提示立刻消失、速度回原样）。
    func shouldSwallowTap() -> Bool {
        let disposition = Self.tapDisposition(
            isHolding: isSpeedBoostHolding,
            pressStartedAt: speedBoostPress?.startedAt,
            pressEndedAt: speedBoostPress?.endedAt,
            now: Date()
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
            consumePressSession()
            return false
        case .endStaleBoost:
            endSpeedBoost(reason: "自愈（挂太久）")
            consumePressSession()
            return false
        }
    }

    /// 这次按住的账（按下 / 松手时刻）到此为止：尾巴点按只吞它自己那一下；
    /// 拖动 / 布局变化 / 退到后台这类「不会再有尾巴点按」的路径也顺手结清。
    func consumePressSession() {
        speedBoostPress = nil
    }
}
