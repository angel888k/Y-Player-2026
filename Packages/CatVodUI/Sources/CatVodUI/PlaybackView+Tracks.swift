import CatVodPlayer
import SwiftUI

/// 播放页的**轨道**（视轨 / 音轨 / 字幕轨）：信息区那一段择项 + 三个选择绑定。
///
/// 为什么要拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint `file_length` 的 error 线（800）——
/// 与 `+Controls` / `+Engine` / `+Speed` / `+Stats` 同一套做法；跨文件用到的成员本来就是模块内。
extension PlaybackView {
    /// 音轨 / 字幕轨选择。
    ///
    /// **只有内核报了轨道才出现**：三个内核都会报（系统内核 M03P7、MPV M03P5、自研 FFmpeg M04P16）——
    /// 报不出来就不显示这一块，不做「点不动的假菜单」。
    /// 轨名优先用内核报的 `label`（语言 / 标题，M03P8），读不到退「音轨 <id>」。
    var tracksSection: some View {
        Section("轨道") {
            if !videoTracks.isEmpty {
                Picker("视轨", selection: videoSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(videoTracks) { track in
                        Text(track.label ?? "视轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
            if !audioTracks.isEmpty {
                Picker("音轨", selection: audioSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    ForEach(audioTracks) { track in
                        Text(track.label ?? "音轨 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
            if !subtitleTracks.isEmpty {
                Picker("字幕", selection: subtitleSelectionBinding) {
                    Text("自动").tag(TrackSelection.auto)
                    Text("关闭").tag(TrackSelection.disabled)
                    ForEach(subtitleTracks) { track in
                        Text(track.label ?? "字幕 \(track.id)").tag(TrackSelection.index(track.id))
                    }
                }
            }
        }
    }

    /// 视轨选择（M26）：改界面态 + 立刻下发内核（`selectTrack`，MPV 落到 `vid`）。
    var videoSelectionBinding: Binding<TrackSelection> {
        Binding(
            get: { videoSelection },
            set: { selection in
                videoSelection = selection
                Task { await engine?.selectTrack(selection, for: .video) }
            }
        )
    }

    /// 音轨选择：改界面态 + 立刻下发内核（`selectTrack`）。
    var audioSelectionBinding: Binding<TrackSelection> {
        Binding(
            get: { audioSelection },
            set: { selection in
                audioSelection = selection
                Task { await engine?.selectTrack(selection, for: .audio) }
            }
        )
    }

    /// 字幕轨选择：同上。
    var subtitleSelectionBinding: Binding<TrackSelection> {
        Binding(
            get: { subtitleSelection },
            set: { selection in
                subtitleSelection = selection
                Task { await engine?.selectTrack(selection, for: .subtitle) }
            }
        )
    }
}
