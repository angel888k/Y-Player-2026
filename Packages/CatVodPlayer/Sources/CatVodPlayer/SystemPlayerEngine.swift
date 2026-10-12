import AVFoundation
import CatVodCore
import Foundation

/// 系统播放内核（`AVPlayer`）。
///
/// 并发说明（重要）：iOS 18 / macOS 15 SDK 起 `AVPlayer` 标注为 `@MainActor`，
/// 因此本内核实现为 `@MainActor` 类（而不是 `actor`）——这既符合 SDK 约束，
/// 也符合 AVFoundation 本身的线程模型。`kind` / `events` 为 `nonisolated`，满足 `PlayerEngine` 协议。
///
/// 职责范围（M2）：保证「接口 → 首页 → 详情 → 选集 → 播放」链路可用。
/// 局限（明确记录，避免误判为“播放器坏了”）：
/// - 只支持系统可解复用/可解码的容器与编码；
/// - HTTP header 通过 `AVURLAssetHTTPHeaderFieldsKey` 注入，对分片/密钥请求覆盖有限，M6 改为本地代理统一注入；
/// - **不提供强制硬解/软解开关**：`decoderMode` 仅被记录，实际由系统决定（UI 需如实说明）。
///
/// 画面（M27）：不再交给 `AVKit.VideoPlayer` —— 本类持有一层自建的 ``SystemVideoSurface``
/// （`AVPlayerLayer`），界面层把它挂进播放页的宿主视图。这样系统内核与 MPV / 自研 FFmpeg
/// **共用同一条控制条与同一套手势**；画面比例（`videoGravity`）与画中画也从这层起。
@MainActor
public final class AVPlayerEngine: PlayerEngine {
    nonisolated public let kind: PlayerEngineKind = .system
    nonisolated public let events: AsyncStream<PlayerEvent>
    /// 用户选择的解码方式（系统内核不支持强制切换，仅记录以便设置页如实展示）。
    nonisolated public let decoderMode: DecoderMode
    /// 画面层（M27）：换掉 `AVKit.VideoPlayer` 后的自建宿主 —— 界面层把它挂进视图层级，
    /// 画面比例（`videoGravity`）与画中画（`AVPictureInPictureController(playerLayer:)`）都从这层起。
    public let videoSurface = SystemVideoSurface()

    // 说明：以下存储属性为模块内可见（非 private），因为就绪轮询与事件观测放在
    // `SystemPlayerEngine+Monitoring.swift`（`private` 是文件作用域，跨文件无法访问）。
    var continuation: AsyncStream<PlayerEvent>.Continuation?
    let player = AVPlayer()
    /// 用户请求的倍速。
    ///
    /// 为什么必须记着它：`AVPlayer.play()` 等价于「rate 置 1」，于是「设了 1.5x → 暂停 → 继续」
    /// 会悄悄退回正常速度（M02P15 修的就是这个）。`play()` 现在按这里记的值恢复。
    var requestedRate: Float = SpeedSetting.normal
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var monitoringTask: Task<Void, Never>?
    var state: PlayerState = .idle
    var lastTime: Double = 0
    var duration: Double = 0

    public init(decoderMode: DecoderMode = .hardware) {
        self.decoderMode = decoderMode
        var captured: AsyncStream<PlayerEvent>.Continuation?
        let stream = AsyncStream<PlayerEvent> { captured = $0 }
        events = stream
        continuation = captured
        // 画面层挂上播放器（M27）：一个引擎实例一层（换内核 = 换引擎 = 换层）。
        videoSurface.layer.player = player
    }

    public func currentState() async -> PlayerState {
        state
    }

    /// 底层 `AVPlayer` 实例。
    ///
    /// M27 起界面用的是 ``videoSurface`` 的画面层（不再有 `AVKit.VideoPlayer` 要绑）；
    /// 这个方法留给测试与排查（音量 / 倍速这类的断言都读它）。
    public func systemPlayer() -> AVPlayer {
        player
    }

    /// 结束事件流（由持有者在销毁内核时调用；`teardown()` 不会结束流，便于复用引擎加载下一个视频）。
    public func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    // MARK: - 命令

    public func load(_ resource: MediaResource) async throws {
        guard let url = URL(string: resource.url), url.scheme != nil else {
            throw PlayerError.invalidURL(resource.url)
        }
        await teardown()
        update(.loading)

        let item = AVPlayerItem(asset: Self.makeAsset(url: url, headers: resource.headers))
        duration = 0
        // 每条资源从正常速度起播：倍速是「本次播放的偏好」，由上层加载后自己套用（播放页从存档读）。
        requestedRate = SpeedSetting.normal
        lastTime = max(resource.startPosition, 0)
        player.replaceCurrentItem(with: item)
        installObservers(item: item)

        if resource.startPosition > 0 {
            // 用 completion-handler 版本（经 seekAsync 包装）：
            // 直接写 player.seek(to:) 会被解析成 async 重载，行为与完成回调不一致。
            await seekAsync(to: CMTime(seconds: resource.startPosition, preferredTimescale: 600))
        }
        startMonitoring()
    }

    public func play() async {
        player.play()
        // `AVPlayer.play()` 等价于把 rate 置 1：把记着的倍速找回来，否则「设 1.5x → 暂停 → 继续」会退回 1.0x。
        if player.rate != requestedRate {
            player.rate = requestedRate
        }
        update(.playing)
    }

    public func pause() async {
        player.pause()
        update(.paused)
    }

    public func seek(to seconds: Double) async {
        let target = max(seconds, 0)
        await seekAsync(to: CMTime(seconds: target, preferredTimescale: 600))
        lastTime = target
        emit(.timeChanged(current: target, duration: duration))
    }

    /// 设倍速。
    ///
    /// 注意 AVFoundation 的语义：`rate != 0` 就等于「在播」——暂停状态下设倍速会**开始播放**
    /// （与上游 ExoPlayer 的 `setSpeed` 同类）。播放页只在用户操作时调用，所以不额外拦。
    public func setRate(_ rate: Float) async {
        requestedRate = rate
        player.rate = rate
        emit(.speedChanged(rate))
    }

    /// 音量（0...1）：写 `AVPlayer.volume` —— 这是 App 内的相对音量，系统音量仍归硬件键。
    public func setVolume(_ volume: Float) async {
        player.volume = min(max(volume, 0), 1)
    }

    /// 音量增益（M04P23）：系统内核做不到 —— `AVPlayer.volume` 上限就是 1，放大不了。
    /// 空实现（界面按 ``PlayerEngineKind/supportsAudioGain`` 不给它摆控件，不摆假开关）。
    public func setAudioGain(_ gain: Float) async { }

    /// 逐帧步进（M04P23）：`AVPlayerItem.step(byCount:)` **要求先暂停** ——
    /// 播放中调它就把播放停下（与另外两个内核「先暂停再走一帧」同一口径）。
    /// `canStepForward` 为假时什么都不做（不假装走了）。
    public func stepFrame() async {
        guard let item = player.currentItem else { return }
        if player.rate != 0 {
            await pause()
        }
        guard item.canStepForward else { return }
        item.step(byCount: 1)
    }

    /// 轨道选择（M03P7）：音轨 / 字幕轨走 `AVMediaSelectionGroup`。
    ///
    /// 三态与上游一致：`auto` = 该组的默认轨、`disabled` = 空选择（字幕「关闭」）、
    /// `index` = 第 index 个可选项（下标由 `tracksChanged` 报出去，原样送回来即可）。
    public func selectTrack(_ selection: TrackSelection, for kind: TrackKind) async {
        applyTrackSelection(selection, for: kind)
    }

    /// 画面比例（M03P9 / M27）：画面是自建的 `AVPlayerLayer` 宿主，写它的 `videoGravity`。
    ///
    /// 三态之外（16:9 / 4:3）映射不出来，`SystemVideoSurface.setScaleMode` 里静默不动 ——
    /// 界面本来也不会对本内核列那两档（见 `PlaybackScaleMode.supportedModes(by:)`）。
    public func setScaleMode(_ mode: PlaybackScaleMode) async {
        videoSurface.setScaleMode(mode)
    }

    public func teardown() async {
        monitoringTask?.cancel()
        monitoringTask = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 内部

    /// 按站点 header 构造 asset；无 header 时走系统默认缓存/网络行为。
    static func makeAsset(url: URL, headers: [String: String]) -> AVURLAsset {
        guard !headers.isEmpty else {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    /// 跳转容差（正负 0.5 秒，见 ``seekAsync(to:)`` 的说明）。
    static let seekTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// 带容差的跳转。
    ///
    /// **不要用 `.zero` 容差**（M28P11）：那是「精确到帧」—— AVFoundation 必须从上一个同步帧
    /// 一路解到那一刻，长 GOP / 高码率的片子上就是「快进 / 快退半天不动」（用户报
    /// 「快退或者快进视频的加载速度慢」）。半秒容差与参考实现（ExoPlayer 的
    /// `SeekParameters.CLOSEST_SYNC`）同一类取舍：落点差半秒肉眼看不出来，但少解小半个 GOP ——
    /// 这也是 AVFoundation 官方口径（给容差就是为了响应速度）。
    func seekAsync(to time: CMTime) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            player.seek(to: time, toleranceBefore: Self.seekTolerance, toleranceAfter: Self.seekTolerance) { _ in
                continuation.resume()
            }
        }
    }

    func update(_ newState: PlayerState) {
        state = newState
        emit(.stateChanged(newState))
    }

    func emit(_ event: PlayerEvent) {
        continuation?.yield(event)
    }
}
