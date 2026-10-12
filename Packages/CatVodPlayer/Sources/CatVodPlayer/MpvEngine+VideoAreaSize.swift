import Foundation

/// 画面区尺寸 → mpv 的转告（M27 首验之六之十起；M28 首验之二十六：合并 + 串行；之二十七：先探自认 +
/// 时间账；之二十八：稳定后自愈探针）。
///
/// 为什么单拆一个文件：这套逻辑加上文档把 `MpvEngine` 的类型体推过了 SwiftLint `type_body_length`
/// 的 warning 线（300）—— 与 `PlaybackView+*` / `VodDetailView+*` 同一套做法（拆职责，不拆碎）。
/// 代价和那边一样：扩展里的成员**不能写 `private`**，三个账本（存储属性）也只能留在主声明里、
/// 一并去掉 `private`。
extension MpvEngine {
    /// 画面区（宿主视图）换了尺寸就转告 mpv（M27 首验之六之十）。
    ///
    /// 为什么必须转：`--wid` 嵌的是**这一层**，层变大变小 mpv **不会自己知道** —— 它会一直按
    /// 窗口创建那一刻的尺寸出画（画面小一块、钉在层的左上角；层 / 宿主 / 窗口三处的数值全是对的）。
    ///
    /// 为什么要**合并 + 串行**（M28 首验之二十六）：每次「重建视频输出」都要把整个 VO 拆掉再建回来，
    /// 拆建期间 mpv 不产帧 —— 那是**实打实的一停**。而一次「竖屏 → 横屏就地放大」会连着报两次尺寸
    /// （横屏槽位那一版 + 放大后的最终版）：以前每次回调各起一个 `Task`，命令还会交错下
    /// （两套 `vo=null` / `vo=gpu-next` 撞在一起，画面停两下）。现在：同一批尺寸只落**最后**那个，
    /// 一次只收尾一批，收尾期间来的尺寸留给下一批。
    public func setVideoAreaSize(_ size: CGSize) async {
        guard session != nil, size.width > 0, size.height > 0 else {
            return
        }
        // 每一次上报都把时间锚点推到现在（M28 首验之二十八）：下面几条日志都用它，「尺寸什么时候到的」
        // 与「重建什么时候落下」一眼能对上 —— 用户看到的那一顿到底是重建本身，还是重建和转屏动画撞了车，
        // 全靠这个时间轴分。
        lastVideoAreaReportAt = Date()
        lastVideoAreaSize = size
        guard appliedVideoAreaSize != size, pendingVideoAreaSize != size else {
            return
        }
        // 尺寸还在动：中间那些尺寸的自愈探针是有害的（S2 会替中间尺寸盖一个「没自愈」的章），收掉。
        videoSettleProbeTask?.cancel()
        videoSettleProbeTask = nil
        pendingVideoAreaSize = size
        if videoAreaFlushTask == nil {
            videoAreaFlushTask = Task { await self.flushVideoAreaSizes() }
        }
        await videoAreaFlushTask?.value
    }

    /// 合并窗口（纳秒）：约几帧 —— 转屏 + 就地放大那两次尺寸上报就在这个量级里。
    ///
    /// 取小值是**故意的**：这个窗口是「等同一批尺寸到齐」用的，拖长了会让画面晚一拍跟上新尺寸。
    static let videoAreaMergeNanoseconds: UInt64 = 80_000_000

    /// 收尾一批尺寸上报：先等一个几帧的合并窗口，再只重建一次 VO —— 落窗口里最后到的那个尺寸。
    ///
    /// 循环而不是单次：重建期间又来了新尺寸（比如转屏动画里还有第三版），就用最新那个再落一次。
    /// 循环尾到头之间**没有 await**，所以「检查完 pending 再清任务句柄」这段不会被打断 ——
    /// 不会留下一个没人处理的 pending。
    func flushVideoAreaSizes() async {
        defer { videoAreaFlushTask = nil }
        try? await Task.sleep(nanoseconds: Self.videoAreaMergeNanoseconds)
        while let next = pendingVideoAreaSize {
            pendingVideoAreaSize = nil
            guard session != nil, appliedVideoAreaSize != next else {
                continue
            }
            appliedVideoAreaSize = next
            let arrived = Self.videoAreaArrival(lastVideoAreaReportAt, size: lastVideoAreaSize)
            await rebuildVideoOutput(size: next, arrived: arrived)
        }
    }

    /// 把画面区的新尺寸交给 mpv：**先看它自己认不认，不认才重建视频输出**。
    ///
    /// 第一招（M28 首验之二十七）—— **看一眼它自己认没认**：宿主已经把 `drawableSize` 同步过去了，
    /// MoltenVK 的 surface 尺寸跟着变，mpv 可能自己就发现了。认下就**什么都不用做** ——
    /// 不用拆 VO（拆一次画面停一次，那正是用户还能看到的那一顿）。判据就是 mpv 自己那份
    /// `osd-dimensions`（它按多大在画，它自己最清楚）。
    ///
    /// 第二招 —— **重建视频输出**：`vo` 置空再设回来，mpv 会把 VO 整个重建，重建时会重新读窗口大小
    /// （不改播放位置、不重新拉流）。顺手量一下「它多久认下新尺寸」——用户看到的那一顿就是它。
    func rebuildVideoOutput(size: CGSize, arrived: String) async {
        guard let session else {
            return
        }
        let scale = videoSurface?.layer.contentsScale ?? 2
        let pixelWidth = max(Int((size.width * scale).rounded()), 1)
        let pixelHeight = max(Int((size.height * scale).rounded()), 1)
        let area = "\(pixelWidth)x\(pixelHeight)（点 \(Int(size.width))x\(Int(size.height))）"
        // 重建之前 mpv 认的是什么尺寸：与重建后那一条对照，能看出「这次重建到底换没换掉那个尺寸」
        // （M28 首验之二十八）。
        let dimensionsBefore = session.propertyString("osd-dimensions") ?? "无"
        guard !videoOutputMatches(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            MpvTrace.logger.notice("画面区 \(area, privacy: .public) 由 mpv 自己认下，没重建 VO")
            return
        }
        // 尺寸站稳之后，让一条独立探针看着 mpv 会不会**自己**认下这个尺寸（M28 首验之二十八）：
        // 真认下 = 这次重建本来就能省（重建得比人快，见 ``startSelfHealingProbe``）。
        startSelfHealingProbe(session: session, pixelWidth: pixelWidth, pixelHeight: pixelHeight, area: area)
        let startedAt = Date()
        // 分两段量（M28 首验之二十八）：命令本身（拆 VO + 建 VO）与「认下新尺寸」是两笔账 ——
        // 若「建」占大头，耗在 MoltenVK 重建整条 Vulkan 设备上，省下的办法不是早做，是别拆；
        // 若「认下」占大头，耗的是等 mpv 重建 swapchain，那就该把重建挪进动画里。
        session.command(["set", "vo", "null"])
        let tornDownAt = Date()
        session.command(["set", "vo", "gpu-next"])
        let rebuiltAt = Date()
        let matched = await waitForVideoOutput(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let confirmedAt = Date()
        let elapsed = Int(confirmedAt.timeIntervalSince(startedAt) * 1000)
        let tearDownMs = Int(tornDownAt.timeIntervalSince(startedAt) * 1000)
        let rebuildMs = Int(rebuiltAt.timeIntervalSince(tornDownAt) * 1000)
        let confirmMs = Int(confirmedAt.timeIntervalSince(rebuiltAt) * 1000)
        let matchedText = matched ? "是" : "否"
        let dimensions = session.propertyString("osd-dimensions") ?? "无"
        let line = "画面区 \(area) 已重建 VO（\(elapsed) ms，认下 = \(matchedText)）；"
            + "尺寸到于 \(arrived)｜拆 \(tearDownMs) ms｜建 \(rebuildMs) ms｜认下 \(confirmMs) ms；"
            + "重建前 \(dimensionsBefore)；重建后 \(dimensions)"
        MpvTrace.logger.notice("\(line, privacy: .public)")
    }

    /// 尺寸站稳之后的**自愈探针**（M28 首验之二十八）：不看别的，就看 mpv 会不会**自己**认下新尺寸。
    ///
    /// 为什么要它：用户点的判据（之二十七）落在「每次重建 422ms」上，但 422ms 是**已经决定重建之后**
    /// 测出来的 —— 「必须重建」这个前提本身还没被证伪。宿主已经把 ``MpvVideoSurface/layer`` 的
    /// `drawableSize` 同步过去了，MoltenVK 的 surface 尺寸跟着变：mpv 的 `--wid` 窗口路径**可能**
    /// 在下一次渲染循环里自己读到新尺寸（那就根本不用拆 VO，也就没有那一顿）。
    ///
    /// 探针只记日志、不改任何状态（重建照走 —— 这条是诊断，不是行为）：它拿到的结论是
    /// 「下一次怎么修」的判据 ——
    /// - 若日志里出现「自愈成功」：把重建挪到探针那个时刻就行（尺寸到 → 等它，认下就免了重建）；
    /// - 若探针蹲满 ``videoSettleProbeNanoseconds`` 也不认：`--wid` 这条路**确认**不认，
    ///   要免掉这一顿只剩「别拆 VO」（render API 自己管画面层）那条路。
    ///
    /// 时间起点是**尺寸稳定**（合并窗口走完、重建落下）之后 —— 早于此的探针会读到「窗口在动」
    /// 的中间态，记下来的不算数。
    func startSelfHealingProbe(
        session: any MpvSession,
        pixelWidth: Int,
        pixelHeight: Int,
        area: String
    ) {
        videoSettleProbeTask?.cancel()
        videoSettleProbeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.videoSettleProbeNanoseconds)
            guard !Task.isCancelled, let self else {
                return
            }
            guard await sessionIsAlive(session) else {
                return
            }
            let startedAt = Date()
            let matched = await waitForVideoOutput(
                session,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let dimensions = session.propertyString("osd-dimensions") ?? "无"
            let verdict = matched
                ? "自愈成功（等 \(elapsed) ms 自己认下了新尺寸）→ 这次重建本来就能省"
                : "自愈超时（蹲满 \(elapsed) ms 没认）→ 要免掉这一顿只能不拆 VO，走 render API"
            let line = "画面区 \(area) 自愈探针：\(verdict)；osd-dimensions = \(dimensions)"
            MpvTrace.logger.notice("\(line, privacy: .public)")
        }
    }

    /// 探针用：会话还是不是原来那个（重建/换片会把会话换掉，那时探针的结论就不作数了）。
    func sessionIsAlive(_ session: any MpvSession) -> Bool {
        self.session === session
    }

    /// 时间戳格式（M28 首验之二十八）：`HH:mm:ss.SSS` —— 与 `log show` 自带的时间对得上，
    /// 「尺寸到于 / 重建落下」之间的间隔一眼能量。
    static func videoAreaTimestamp(_ date: Date?) -> String {
        guard let date else {
            return "未记"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// 「尺寸到于」那一段的全文（时间 + 尺寸，按**点**写）：日志里一条就能对上
    /// 「哪一次上报触发了这次重建」（M28 首验之二十八）。
    static func videoAreaArrival(_ date: Date?, size: CGSize?) -> String {
        let time = videoAreaTimestamp(date)
        guard let size else {
            return time
        }
        return "\(time)（\(Int(size.width))x\(Int(size.height)) 点）"
    }

    /// mpv 现在认的视频输出尺寸是不是这个（读 `osd-dimensions` 的 `w` / `h`）。
    func videoOutputMatches(_ session: any MpvSession, pixelWidth: Int, pixelHeight: Int) -> Bool {
        guard let dimensions = session.propertyString("osd-dimensions") else {
            return false
        }
        return dimensions.contains("\"w\":\(pixelWidth)") && dimensions.contains("\"h\":\(pixelHeight)")
    }

    /// 等 mpv 认下这个尺寸：认下返回 `true`，超时返回 `false`（上限见常量 —— 重建是一瞬的事，
    /// 别在这儿死等）。
    func waitForVideoOutput(_ session: any MpvSession, pixelWidth: Int, pixelHeight: Int) async -> Bool {
        var remaining = Self.videoOutputMatchTimeoutNanoseconds
        while remaining > 0 {
            if videoOutputMatches(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
                return true
            }
            try? await Task.sleep(nanoseconds: Self.videoOutputPollNanoseconds)
            remaining -= min(Self.videoOutputPollNanoseconds, remaining)
        }
        return videoOutputMatches(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    /// 等 mpv 认下新尺寸的上限（纳秒）：半秒（重建是一瞬的事，超时就是没认）。
    static let videoOutputMatchTimeoutNanoseconds: UInt64 = 500_000_000
    /// 轮询间隔（纳秒）：20ms —— 一帧多，比固定睡 300ms 更快也更准。
    static let videoOutputPollNanoseconds: UInt64 = 20_000_000
    /// 自愈探针的下蹲时长（纳秒）：3.5 秒 —— 够长到「mpv 一辈子都不会自己认」这种情况能落个准信，
    /// 又不至于让日志里老挂着一个没结论的探针（详见 ``startSelfHealingProbe``）。
    static let videoSettleProbeNanoseconds: UInt64 = 3_500_000_000
}
