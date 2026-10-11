import Foundation

/// 画面区尺寸 → mpv 的转告（M27 首验之六之十起；M28 首验之二十六：合并 + 串行；之二十七：先探自认）。
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
        guard appliedVideoAreaSize != size, pendingVideoAreaSize != size else {
            return
        }
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
            await rebuildVideoOutput(size: next)
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
    func rebuildVideoOutput(size: CGSize) async {
        guard let session else {
            return
        }
        let scale = videoSurface?.layer.contentsScale ?? 2
        let pixelWidth = max(Int((size.width * scale).rounded()), 1)
        let pixelHeight = max(Int((size.height * scale).rounded()), 1)
        let area = "\(pixelWidth)x\(pixelHeight)（点 \(Int(size.width))x\(Int(size.height))）"
        guard !videoOutputMatches(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            MpvTrace.logger.notice("画面区 \(area, privacy: .public) 由 mpv 自己认下，没重建 VO")
            return
        }
        let startedAt = Date()
        session.command(["set", "vo", "null"])
        session.command(["set", "vo", "gpu-next"])
        let matched = await waitForVideoOutput(session, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
        let matchedText = matched ? "是" : "否"
        let dimensions = session.propertyString("osd-dimensions") ?? "无"
        let line = "画面区 \(area) 已重建 VO（\(elapsed) ms，认下 = \(matchedText)）；osd-dimensions = \(dimensions)"
        MpvTrace.logger.notice("\(line, privacy: .public)")
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
}
