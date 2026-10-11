import Foundation

#if os(iOS)
import AVFAudio
#endif

/// 播放期间的**音频会话**（iOS）：画中画与「后台继续出声」都要求 `.playback` 这一档。
///
/// | 平台 | 实现 |
/// | --- | --- |
/// | iOS | `AVAudioSession` 设 `.playback` + 激活（进播放页激活、离开还原） |
/// | macOS | 没有「音频会话」这个概念，空操作 |
///
/// 为什么用引用计数：详情页的**就地播放器**点 ⤢ 转全屏那一下，两个 `PlaybackView` 会短暂并存 ——
/// 后一个离场时的 `deactivate` 不能把前一个还在用的会话关掉。
///
/// 设不上就**如实算了**（播放照旧，只是没有画中画 / 后台出声）—— 不拦播放、不摆假开关。
public enum PlaybackAudioSession {
    @MainActor private static var activeCount = 0

    /// 播放页出现：激活（只有从 0 到 1 那一次真正动会话）。
    @MainActor
    public static func activate() {
        activeCount += 1
        #if os(iOS)
        guard activeCount == 1 else {
            return
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif
    }

    /// 播放页离场：计数归零才还原（`notifyOthersOnDeactivation` 让别的 App 自己恢复）。
    @MainActor
    public static func deactivate() {
        activeCount = max(0, activeCount - 1)
        #if os(iOS)
        guard activeCount == 0 else {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
