import Foundation

/// 播放页的「画面比例 / 缩放」（M03P9，对齐参考实现 `select_scale` + `player.setResizeMode`）。
///
/// **档位表对齐参考截图**（M28 首验之十八）：适应屏幕 / 裁剪全屏 / 拉伸全屏 / 4:3 / 5:4 / 16:9 /
/// 21:9 / 2.39:1，默认「适应屏幕」。每一档都写清**哪个内核做得到**：
///
/// | 档位 | MPV | 自研 FFmpeg | 系统内核 |
/// | --- | --- | --- | --- |
/// | 适应屏幕 / 裁剪全屏 / 拉伸全屏 | ✅ | ✅（`videoGravity` 三态） | ✅（M27 起：`AVPlayerLayer.videoGravity`） |
/// | 4:3 / 5:4 / 16:9 / 21:9 / 2.39:1 | ✅（`video-aspect-override`） | ❌ | ❌ |
///
/// 界面只列**当前内核真的支持**的档位（``supportedModes(by:)``）—— 内核整行都不支持时这一项不出现，
/// 不摆点了没反应的开关（「解码方式对系统内核无效」那条是标注，这个干脆不显示）。
public enum PlaybackScaleMode: String, Sendable, CaseIterable, Hashable {
    /// 适应屏幕（默认）：保持比例，留黑边。
    case fit
    /// 裁剪全屏：保持比例放大到铺满，超出部分裁掉。
    case crop
    /// 拉伸全屏：不保持比例，直接铺满（画面会变形）。
    case stretch
    /// 强制按 4:3 显示。
    case ratio4x3
    /// 强制按 5:4 显示。
    case ratio5x4
    /// 强制按 16:9 显示。
    case ratio16x9
    /// 强制按 21:9 显示。
    case ratio21x9
    /// 强制按 2.39:1 显示。
    case ratio239

    public var displayName: String {
        switch self {
        case .fit: "适应屏幕"
        case .crop: "裁剪全屏"
        case .stretch: "拉伸全屏"
        case .ratio4x3: "4:3"
        case .ratio5x4: "5:4"
        case .ratio16x9: "16:9"
        case .ratio21x9: "21:9"
        case .ratio239: "2.39:1"
        }
    }

    /// 从进度记录里的存档串还原（M03P19）：空串 / 认不出的值回落 ``fit`` ——
    /// 坏存档不该让画面变形（与「坏倍速回正常速度」同一口径）。
    public static func decode(_ raw: String?) -> PlaybackScaleMode {
        guard let raw, let mode = PlaybackScaleMode(rawValue: raw) else {
            return .fit
        }
        return mode
    }

    /// 某个内核实不实做得到这一档。
    public func isSupported(by engine: PlayerEngineKind) -> Bool {
        switch engine {
        case .system:
            // 系统内核（M27）：画面换成自建 `AVPlayerLayer` 宿主之后，三态 gravity 也有了 ——
            // 「强制某个比例」仍表达不了（要自己算层的 frame，与自研内核同一口径）。
            self == .fit || self == .crop || self == .stretch
        case .mpv:
            true
        case .ffmpeg:
            // 自研内核只有 `AVSampleBufferDisplayLayer.videoGravity` 三态：「强制某个比例」
            // gravity 表达不了（要自己算层的 frame，不在这一轮的范围里）。
            self == .fit || self == .crop || self == .stretch
        }
    }

    /// 某内核支持的档位（保持声明顺序）；**空数组 = 这个内核没有这个能力**。
    public static func supportedModes(by engine: PlayerEngineKind) -> [PlaybackScaleMode] {
        allCases.filter { $0.isSupported(by: engine) }
    }
}
