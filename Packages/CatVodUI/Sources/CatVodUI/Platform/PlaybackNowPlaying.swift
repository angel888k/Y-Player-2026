import Foundation

#if os(iOS)
import MediaPlayer

/// 「控制中心显示」（M28，设置 → 播放器 → 播放控制）：把正在播的剧名 / 时长 / 进度 / 播放状态
/// 发布到**系统控制中心与锁屏**，并把「播放 / 暂停 / 上一集 / 下一集」接回播放页。
///
/// 为什么放这里而不是各内核里：三个内核共用播放页这一层（M27），发布的信息也就该由它给 ——
/// 内核是谁都不影响控制中心里显示什么。画中画那一份由系统自己发布（PiP 在播时我们让路，
/// 别两份信息打架，见 `PlaybackView` 的调用点）。
///
/// 口径：
/// - 发布的是**能确知的四项**（剧名 / 时长 / 当前进度 / 速率），不猜封面、不编作者；
/// - 上一集 / 下一集两条命令**只有能换集时**才注册（直播 / 下载播放没有播放列表）；
/// - macOS 这一版不做（与画中画同一口径）：``isSupported`` 为假，设置页那一行不出现。
@MainActor
enum PlaybackNowPlaying {
    /// 这个平台支不支持（设置页据此决定那一行摆不摆）。
    static let isSupported = true

    /// 正在发布的元信息（`update` 用；`deactivate` 清掉）。
    private struct Published {
        var title: String
        var duration: Double
    }

    private static var published: Published?
    /// 注册过的远程命令（`deactivate` 要按同一个 center 摘掉）。
    private static var tokens: [(command: MPRemoteCommand, token: Any)] = []

    /// 开始发布：给剧名，并把三条命令接上（`onNext` / `onPrevious` 传 nil = 没得换，不注册）。
    ///
    /// 回调都在主线程（`MPRemoteCommandCenter` 保证），因此调用方能直接碰播放页的状态。
    static func activate(
        title: String,
        onPlayPause: @escaping () -> Void,
        onNext: (() -> Void)?,
        onPrevious: (() -> Void)?
    ) {
        deactivate()
        published = Published(title: title, duration: 0)
        let center = MPRemoteCommandCenter.shared()
        tokens.append((center.playCommand, center.playCommand.addTarget { _ in
            onPlayPause()
            return .success
        }))
        tokens.append((center.pauseCommand, center.pauseCommand.addTarget { _ in
            onPlayPause()
            return .success
        }))
        tokens.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { _ in
            onPlayPause()
            return .success
        }))
        center.nextTrackCommand.isEnabled = onNext != nil
        if let onNext {
            tokens.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { _ in
                onNext()
                return .success
            }))
        }
        center.previousTrackCommand.isEnabled = onPrevious != nil
        if let onPrevious {
            tokens.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { _ in
                onPrevious()
                return .success
            }))
        }
    }

    /// 更新进度 / 状态：三个内核都走这一条（`rate` = 0 表示暂停 / 缓冲，控制中心据此显示暂停态）。
    static func update(position: Double, duration: Double, rate: Double) {
        guard var current = published else {
            return
        }
        if duration > 0 {
            current.duration = duration
        }
        published = current
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: current.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(position, 0),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
        ]
        if current.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = current.duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    /// 停掉发布（离开播放页 / 关掉这个开关）：摘命令、清信息，不留一个挂着旧剧名的控制中心。
    static func deactivate() {
        for entry in tokens {
            entry.command.removeTarget(entry.token)
        }
        tokens = []
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

#else

/// 「控制中心显示」（M28）：macOS 这一版不做 —— ``isSupported`` 为假，调用方按「不做」处理。
@MainActor
enum PlaybackNowPlaying {
    static let isSupported = false

    static func activate(
        title _: String,
        onPlayPause _: @escaping () -> Void,
        onNext _: (() -> Void)?,
        onPrevious _: (() -> Void)?
    ) { }

    static func update(position _: Double, duration _: Double, rate _: Double) { }

    static func deactivate() { }
}

#endif
