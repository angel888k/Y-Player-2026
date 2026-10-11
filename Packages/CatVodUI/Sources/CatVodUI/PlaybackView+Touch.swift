import SwiftUI

/// 播放页的**触摸分派**（M28 首验之十二）：点按 / 双击 / 长按加速 / 拖动全走一条
/// `DragGesture(minimumDistance: 0)`，落点也由它给 —— 不再叠 `SpatialTapGesture` / `LongPressGesture`。
///
/// 为什么要这么写（三次首验的教训都记在 ``touchGesture`` 的说明里）：只要视频层上有一条「成功」的
/// 长按，画面那条拖动就被整个按死（滑动没反应），而长按「什么时候算成功」在各版本上并不诚实。
///
/// 为什么从 `PlaybackView+Gestures.swift` 拆出来：那个扩展的类型体行数顶到了 SwiftLint
/// `type_body_length` 的 error 线（450）—— 与 `+Controls` / `+BarMenus` / `+Speed` 同一套做法：
/// 外壳（`interactiveLayer`）与拖动用的纯逻辑留在 `+Gestures`，这里只放「触摸怎么分发」。
extension PlaybackView {
    // MARK: - 触摸（M28 首验之十二：点按 / 双击 / 长按 / 拖动全走这一条）

    /// 一次触摸的现场（M28 首验之十二）。
    struct PlaybackTouchState {
        /// 这一按已经立过账（第一帧 `onChanged` 里立）。
        var started = false
        /// 动了（超过 ``speedBoostMaxDistance``）：这一按不再算「按住」。
        var moved = false
        /// 成了拖动（超过 ``dragActivateDistance``）：松手走拖动收尾，不走点按。
        var dragging = false
        /// 单击还在等双击窗口（`nil` = 没在等）；连击的两下要离得够近（``doubleTapDistance``）。
        var pendingTap: Task<Void, Never>?
        var pendingTapAt: CGPoint?
        var pendingTapHeld: TimeInterval?
    }

    /// 双击连击窗口（秒）：与系统双击的感觉一致。
    static let doubleTapWindow: TimeInterval = 0.35
    /// 连击的两下允许离多远（pt）：离远了就是两个单击（不然快速点两处会点成播放 / 暂停）。
    static let doubleTapDistance: CGFloat = 60
    /// 拖动激活线（pt）：超过它才算「在拖」，之前的都算「点按 / 按住」。
    static let dragActivateDistance: CGFloat = 24

    /// 画面上的**唯一**一条触摸手势：按下 / 移动 / 松手三件事，点按、双击、长按加速、拖动全在这儿分派。
    ///
    /// 为什么不让 SwiftUI 的长按 / 点按各管一段（M28 首验之十、十一、十二连踩三次）：
    /// - 只要这条触摸上有一条「成功」的长按，画面那条拖动就被整个按死（**滑动全没有反应**）——
    ///   而长按「什么时候算成功」在各版本上并不诚实（门槛提到 1.5 秒，短按照样成功过）；
    /// - 「点按会不会被长按吃掉 / 落点给不给」也随版本变（`SpatialTapGesture` 只在 iOS 16+ 有）。
    ///
    /// 现在是自己的账：第一帧 = 按下（记时刻、排「按住计时」）→ 动超过 ``speedBoostMaxDistance``
    /// 撤计时 → 到 ``dragActivateDistance`` 算拖动（进度 / 亮度 / 音量 / 纵甩，全走原来那套纯逻辑）
    /// → 松手：先收加速，再按连击窗口分派单击 / 双击。落点一直都有（`startLocation`），不挑版本。
    func touchGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleTouchChanged(value, width: width)
            }
            .onEnded { value in
                handleTouchEnded(value, width: width)
            }
    }

    /// 按下 / 移动：立「按住」的账、判「动了没有」、到线之后整段拖动逻辑跑起来（原来是 `playerGesture` 的 onChanged）。
    private func handleTouchChanged(_ value: DragGesture.Value, width: CGFloat) {
        let distance = max(abs(value.translation.width), abs(value.translation.height))
        if !touch.started {
            // 第一帧 = 按下：立账、排「按住 → 起加速」的计时（锁上 / 捏合里不立 —— 上游同款）。
            touch.started = true
            touch.moved = false
            touch.dragging = false
            if !isLocked, !isZooming {
                beginSpeedBoostPress()
            }
        }
        if isZooming {
            // 捏合来了：这一按既不算「按住」也不算点按 —— 账立成拖动（收尾会因 isZooming 自己早退）。
            touch.moved = true
            touch.dragging = true
            endSpeedBoost(reason: "捏合中（不是按住加速）")
        } else if !touch.moved, distance > Self.speedBoostMaxDistance {
            // 动了：这一按不再算「按住」—— 计时撤掉；起过的加速由拖动接手或松手收。
            touch.moved = true
            endSpeedBoost(reason: "动了（不是按住加速）")
        }
        if !touch.dragging, distance >= Self.dragActivateDistance {
            // 这条触摸是拖动：把「按住」那条账整条销掉（点按 / 长按都不再掺和）。
            touch.dragging = true
            finishSpeedBoostSession(reason: "开始拖动（不是按住加速）")
        }
        guard !isZooming, !isLocked, touch.dragging else {
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

    /// 松手：先收加速，再按连击窗口分派单击 / 双击（原来两个点按回调 + 长按的收尾全在这儿）。
    private func handleTouchEnded(_ value: DragGesture.Value, width: CGFloat) {
        let wasDragging = touch.dragging
        touch.started = false
        touch.moved = false
        touch.dragging = false
        if wasDragging {
            settleDrag(value, width: width)
            return
        }
        // 松手 = 加速到此为止（不管后面点按吞不吞）：按住计时撤掉、提示消失、速度回用户那份。
        speedBoostArmTask?.cancel()
        speedBoostArmTask = nil
        endSpeedBoost(reason: "松手")
        // 点按 / 双击的分派：按住时长按**松手那一刻**量（等双击窗口那 0.35 秒不能算进去）。
        let held = currentPressSeconds
        let location = value.startLocation
        let isSecond: Bool
        if let at = touch.pendingTapAt {
            isSecond = abs(at.x - location.x) <= Self.doubleTapDistance
                && abs(at.y - location.y) <= Self.doubleTapDistance
        } else {
            isSecond = false
        }
        if isSecond {
            // 第二下到了：双击 —— 不再等窗口。
            touch.pendingTap?.cancel()
            touch.pendingTap = nil
            touch.pendingTapAt = nil
            touch.pendingTapHeld = nil
            dispatchTap(doubleTap: true, location: location, width: width, held: held)
        } else {
            // 上一按离得远（或本来就没有）：先把还挂着的那一按当单击发出去（两个单击，不是连击），
            // 再给这一按排新的等待。
            flushPendingSingleTap(width: width)
            touch.pendingTap = Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.doubleTapWindow * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                flushPendingSingleTap(width: width)
            }
            touch.pendingTapAt = location
            touch.pendingTapHeld = held
        }
    }

    /// 把「还在等第二下」的那一按按单击发出去（窗口到了 / 来了个离得够远的下一按）。
    private func flushPendingSingleTap(width: CGFloat) {
        guard let at = touch.pendingTapAt else {
            return
        }
        let held = touch.pendingTapHeld
        touch.pendingTap?.cancel()
        touch.pendingTap = nil
        touch.pendingTapAt = nil
        touch.pendingTapHeld = nil
        dispatchTap(doubleTap: false, location: at, width: width, held: held)
    }

    /// 一次点按的动作分派（原来 `adaptiveTapGesture` 的两个回调合到这儿）：
    /// 锁上只留单击；长按的尾巴按量出来的按住时长吞 / 放；其余交给 `handleTap`（动作由设置给）。
    private func dispatchTap(doubleTap: Bool, location: CGPoint, width: CGFloat, held: TimeInterval?) {
        let unlocked = Self.lockedGesturePolicy(isLocked: isLocked) == .all
        let isCenter = Self.isCenterTap(startX: location.x, width: width)
        if doubleTap, !unlocked {
            // 没做事的那些也留一条痕（「哪一段断了」全在日志里，排障不靠猜）。
            PlaybackTrace.noteTap(doubleTap: true, location: location, isCenter: isCenter, action: "（锁上不做）", held: held)
            return
        }
        guard !shouldSwallowTap(held: held) else {
            PlaybackTrace.noteTap(doubleTap: doubleTap, location: location, isCenter: isCenter, action: "（被长按尾巴吞掉）", held: held)
            return
        }
        handleTap(doubleTap: doubleTap, at: location, width: width, held: held)
    }

    /// 拖动收尾（原来是 `playerGesture` 的 onEnded）：纵甩判定 / seek / 音量 / 提示一起收。
    private func settleDrag(_ value: DragGesture.Value, width: CGFloat) {
        speedBoostArmTask?.cancel()
        speedBoostArmTask = nil
        consumePressSession()
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
