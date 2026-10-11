import Foundation

/// 播放页的「画面比例 / 缩放」（M03P9，对齐参考实现 `select_scale` + `player.setResizeMode`）。
///
/// **档位表对齐参考截图**（M28 首验之十八）：适应屏幕 / 裁剪全屏 / 拉伸全屏 / 4:3 / 5:4 / 16:9 /
/// 21:9 / 2.39:1，默认「适应屏幕」。每一档都写清**哪个内核做得到**：
///
/// | 档位 | MPV | 自研 FFmpeg | 系统内核 |
/// | --- | --- | --- | --- |
/// | 适应屏幕 / 裁剪全屏 / 拉伸全屏 | ✅ | ✅（`videoGravity` 三态） | ✅（M27 起：`AVPlayerLayer.videoGravity`） |
/// | 4:3 / 5:4 / 16:9 / 21:9 / 2.39:1 | ✅（`video-aspect-override`） | ✅（M28 首验之十九：内容盒 + `resize`） | ✅（同左） |
///
/// 界面只列**当前内核真的支持**的档位（``supportedModes(by:)``）—— M28 首验之十九起三个内核都全；
/// 这条规矩留给将来的新内核：整行都不支持时这一项不出现，不摆点了没反应的开关。
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

    /// 「强制比例」五档的目标显示比例（宽 ÷ 高）；前三档（适应 / 裁剪 / 拉伸）不是强制比例 = nil。
    ///
    /// 两个 gravity 内核（系统 / 自研）靠界面层的**内容盒**把这一档做出来：画面层缩成目标比例的
    /// 居中盒（`LayerContentBox`）+ `videoGravity = .resize` 把内容拉进盒里 —— 观感与 mpv 的
    /// `video-aspect-override` 一致（视频按目标比例显示，整体留在画面区内）。MPV 不走这里
    /// （走 ``mpvCommands``）。
    public var forcedAspect: CGFloat? {
        switch self {
        case .fit, .crop, .stretch: nil
        case .ratio4x3: 4.0 / 3.0
        case .ratio5x4: 5.0 / 4.0
        case .ratio16x9: 16.0 / 9.0
        case .ratio21x9: 21.0 / 9.0
        case .ratio239: 2.39
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
    ///
    /// M28 首验之十九起三个内核都全：MPV 走 `video-aspect-override`；系统 / 自研走
    /// 「内容盒 + `resize`」（见 ``forcedAspect``）—— 公开 API 都做得到。
    public func isSupported(by engine: PlayerEngineKind) -> Bool {
        switch engine {
        case .system, .mpv, .ffmpeg: true
        }
    }

    /// 某内核支持的档位（保持声明顺序）；**空数组 = 这个内核没有这个能力**。
    public static func supportedModes(by engine: PlayerEngineKind) -> [PlaybackScaleMode] {
        allCases.filter { $0.isSupported(by: engine) }
    }
}
