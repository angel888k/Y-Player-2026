import AVFoundation

/// 自研 FFmpeg 内核的画面目标：一层 `AVSampleBufferDisplayLayer`（M04P5 记录的首选渲染路径）。
///
/// 为什么是它（而不是自绘 Metal）：
/// - demux / 解码我们自己做，**presentation**（HDR/EDR 输出、帧调度、A/V 同步、倍速）
///   交给系统渲染管线；
/// - 它与将来的音频侧（`AVSampleBufferAudioRenderer`）共用一个
///   `AVSampleBufferRenderSynchronizer` 时钟 —— 音画同步是结构上自带的，不是后期调的。
///
/// 与 ``MpvVideoSurface`` 同一套路：
/// - 引擎与界面**都要持有它**（渲染器往层里送样本、界面把层挂进视图层级），
///   生命周期必须比会话长；
/// - `CatVodPlayer` 不 import UIKit/AppKit —— 两端的宿主视图在 `CatVodUI/Platform` 里。
///
/// `@unchecked Sendable`：层的创建与布局在主线程（界面层保证），渲染侧只对它 enqueue/flush。
public final class FFmpegVideoSurface: @unchecked Sendable {
    /// 画面层。界面层负责挂进视图层级；``LibavVideoRenderer`` 负责往里送样本。
    public let layer = AVSampleBufferDisplayLayer()

    public init() { }

    /// 当前画面比例（M28 首验之十九）：界面层建宿主时先按它把「内容盒」套一次。
    public private(set) var scaleMode: PlaybackScaleMode = .fit
    /// 界面层挂的回调：比例变了自己重排「内容盒」（宿主视图 ``LayerHostView/setContentAspect(_:)``）。
    /// 本引擎是 actor：这条回调可能**不在主线程** —— 界面层收尾时要回主线程再动视图。
    public var onScaleModeChanged: ((PlaybackScaleMode) -> Void)?

    /// 画面比例（M03P9；M28 首验之十九补齐比例档）：三态落到 `videoGravity`；比例档 gravity
    /// 单独表达不了 —— 固定 `resize`，由界面层把画面层缩成目标比例的**内容盒**（`LayerContentBox`）
    /// 把内容拉进盒里，观感对齐 mpv 的 `video-aspect-override`。
    public func setScaleMode(_ mode: PlaybackScaleMode) {
        scaleMode = mode
        layer.videoGravity = mode.avVideoGravity ?? .resize
        onScaleModeChanged?(mode)
    }
}

extension PlaybackScaleMode {
    /// 画面层的 `videoGravity` 对应值（M27 起 `AVSampleBufferDisplayLayer` 与 `AVPlayerLayer`
    /// 共用这一份）；`nil` = gravity 单独表达不了（比例档 —— 靠「内容盒 + `.resize`」组合表达，
    /// 见 ``PlaybackScaleMode/forcedAspect``）。
    var avVideoGravity: AVLayerVideoGravity? {
        switch self {
        case .fit: .resizeAspect
        case .crop: .resizeAspectFill
        case .stretch: .resize
        case .ratio4x3, .ratio5x4, .ratio16x9, .ratio21x9, .ratio239: nil
        }
    }
}
