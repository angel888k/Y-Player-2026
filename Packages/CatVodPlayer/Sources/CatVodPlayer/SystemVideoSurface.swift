import AVFoundation

/// 系统内核（AVPlayer）的画面目标：一层 `AVPlayerLayer`（M27：换掉 `AVKit.VideoPlayer`）。
///
/// 为什么换（M27）：`AVKit.VideoPlayer` 自带一整套控件与手势 —— 系统内核因此与 MPV / 自研 FFmpeg
/// 是**两套按钮、两套手势**（旧的「系统控件归系统」口径见 `docs/UI 规范.md` 的历史版本）。
/// 换成自建宿主之后：
/// - 三个内核共用同一条叠层控制条与同一套画面手势（差异只剩内核真做不到的那几项）；
/// - 画面比例（`videoGravity`）系统内核也有了（M03P9 那套档位表补齐一列）；
/// - 画中画从这层起（`AVPictureInPictureController(playerLayer:)`，界面层做，见 `PlaybackPipController`）。
///
/// 与 ``MpvVideoSurface`` / ``FFmpegVideoSurface`` 同一套路：引擎与界面**都要持有它**，
/// 生命周期比会话长；`CatVodPlayer` 不 import UIKit/AppKit —— 两端宿主视图在 `CatVodUI/Platform`。
/// 区别只有一个：这里挂的是 `AVPlayerLayer`（播放器本身归 ``AVPlayerEngine``，不是自绘）。
///
/// `@unchecked Sendable`：层只在主线程创建与布局（界面层保证），引擎侧只在主 actor 上写
/// `player` 与 `videoGravity`。
public final class SystemVideoSurface: @unchecked Sendable {
    /// 画面层。界面层负责挂进视图层级；``AVPlayerEngine`` 把播放器与画面比例写到它上面。
    public let layer = AVPlayerLayer()

    public init() { }

    /// 当前画面比例（M28 首验之十九）：界面层建宿主时先按它把「内容盒」套一次。
    public private(set) var scaleMode: PlaybackScaleMode = .fit
    /// 界面层挂的回调：比例变了自己重排「内容盒」（宿主视图 ``LayerHostView/setContentAspect(_:)``）。
    /// 引擎侧在 `setScaleMode` 里同步调 —— 界面层收尾时要回主线程再动视图。
    public var onScaleModeChanged: ((PlaybackScaleMode) -> Void)?

    /// 画面比例（M03P9 的档位表，M27 补系统内核一列，M28 首验之十九补比例档）：
    /// 前三档（适应 / 裁剪 / 拉伸）落到 `videoGravity`；比例档（4:3 / 5:4 / 16:9 / 21:9 / 2.39:1）
    /// gravity 单独表达不了 —— 固定 `resize`，由界面层把画面层缩成目标比例的**内容盒**
    /// （`LayerContentBox`）把内容拉进盒里，观感对齐 mpv 的 `video-aspect-override`。
    public func setScaleMode(_ mode: PlaybackScaleMode) {
        scaleMode = mode
        layer.videoGravity = mode.avVideoGravity ?? .resize
        onScaleModeChanged?(mode)
    }
}
