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

    /// 画面比例（M03P9 的档位表，M27 补上系统内核这一列）：与自研内核同一套 gravity 三态。
    ///
    /// 比例档（4:3 / 5:4 / 16:9 / 21:9 / 2.39:1）映射不出来（``avVideoGravity`` 是 nil）—— 那些档这里**什么都不做**：
    /// 静默改成「适应」才是说谎；界面本来也不会对系统内核列它们
    /// （见 `PlaybackScaleMode.supportedModes(by:)`）。
    public func setScaleMode(_ mode: PlaybackScaleMode) {
        guard let gravity = mode.avVideoGravity else {
            return
        }
        layer.videoGravity = gravity
    }
}
