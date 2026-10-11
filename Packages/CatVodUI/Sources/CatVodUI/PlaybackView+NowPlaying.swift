import SwiftUI

/// 播放页的「控制中心显示」（M28，设置见「设置 → 播放器 → 播放控制」）。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又顶到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Stats` / `+Engine` / `+Overlays` 同一套做法；跨文件用到的成员（几个 `@State` 与
/// `switchEpisode` / `togglePlayback`）本来就是模块内。
///
/// 发布口径（剧名 / 时长 / 进度 / 状态）与让路画中画那一条，见 `Platform/PlaybackNowPlaying`。
extension PlaybackView {
    /// 把「控制中心显示」接上：剧名 + 三条命令（播放 / 暂停 / 上一集 / 下一集）。
    ///
    /// 没有播放列表（直播 / 下载播放 / 设置页试播）就不注册上 / 下一条 —— 不摆假的换集命令。
    /// 画中画在播时我们**让路**：那一份由系统自己发布，两边一起发就是两份信息打架。
    func activateNowPlaying() {
        PlaybackNowPlaying.activate(
            title: activeTitle,
            onPlayPause: {
                guard !pipController.isActive else {
                    return
                }
                Task { await togglePlayback() }
            },
            onNext: playlist != nil ? { Task { await playNextEpisode() } } : nil,
            onPrevious: playlist != nil ? { Task { await playPreviousEpisode() } } : nil
        )
        lastNowPlayingSecond = -1
    }

    /// 发布一次控制中心信息。`throttled` = 位置事件：**同一秒只发一次** ——
    /// MPV 的位置事件是按帧来的，每帧都往控制中心写一遍纯属浪费。
    func updateNowPlaying(position: Double, duration: Double, isPlaying: Bool, throttled: Bool = false) {
        guard controlSettings.showsControlCenter, PlaybackNowPlaying.isSupported, !pipController.isActive else {
            return
        }
        if throttled {
            let second = Int(position)
            guard second != lastNowPlayingSecond else {
                return
            }
            lastNowPlayingSecond = second
        }
        PlaybackNowPlaying.update(
            position: position,
            duration: duration,
            rate: isPlaying ? playbackRate : 0
        )
    }

    /// 控制中心「下一集 / 上一集」：与片尾连播、纵甩切集走**同一个** `switchEpisode`。
    func playNextEpisode() async {
        if let next = nextEpisodeIndex {
            await switchEpisode(to: next)
        }
    }

    func playPreviousEpisode() async {
        guard let playlist, let current = currentEpisodeIndex, let previous = playlist.previousIndex(before: current) else {
            return
        }
        await switchEpisode(to: previous)
    }
}
