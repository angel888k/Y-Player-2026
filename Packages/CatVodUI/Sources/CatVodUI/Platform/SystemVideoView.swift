import CatVodPlayer
import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 把系统内核的画面层（`SystemVideoSurface.layer`，一层 `AVPlayerLayer`）挂进 SwiftUI 的宿主视图。
///
/// 为什么不再用 `AVKit.VideoPlayer`（M27）：它自带一整套控件与手势 —— 既跟我们的叠层控制条打架，
/// 又让系统内核与 MPV / 自研 FFmpeg 各是一套按钮。换成自建宿主之后，三个内核共用
/// 同一套控制条（`PlaybackView+Controls`）与同一套手势（`PlaybackView+Gestures`）。
///
/// 与 ``MpvVideoView`` / ``FFmpegVideoView`` 同一套路（宿主实现共用 ``LayerHostView``）：
/// 视图只做「挂层 + 跟随尺寸」，层的生命周期归 `SystemVideoSurface`（引擎持有它）。
struct SystemVideoView: UIViewRepresentable {
    let surface: SystemVideoSurface
    /// 画面区量出来的尺寸（SwiftUI 侧递进来）：宿主照它铺满 —— 见 ``LayerHostView/attach(_:sizedTo:)``。
    let size: CGSize

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.backgroundColor = .black
        view.attach(surface.layer, sizedTo: size)
        // 画面比例（M28 首验之十九）：比例档要重排「内容盒」——引擎换比例时回调过来；
        // 回调可能不在主线程（自研内核），回主线程再动视图。
        surface.onScaleModeChanged = { [weak view] mode in
            Task { @MainActor in
                view?.setContentAspect(mode.forcedAspect)
            }
        }
        view.setContentAspect(surface.scaleMode.forcedAspect)
        return view
    }

    func updateUIView(_ view: LayerHostView, context: Context) {
        view.attach(surface.layer, sizedTo: size)
        view.setContentAspect(surface.scaleMode.forcedAspect)
    }
}

#else
import AppKit

/// 把系统内核的画面层挂进 SwiftUI 的宿主视图（macOS）。
struct SystemVideoView: NSViewRepresentable {
    let surface: SystemVideoSurface
    /// 画面区量出来的尺寸（SwiftUI 侧递进来）：宿主照它铺满 —— 见 ``LayerHostView/attach(_:sizedTo:)``。
    let size: CGSize

    func makeNSView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.attach(surface.layer, sizedTo: size)
        // 画面比例（M28 首验之十九）：比例档要重排「内容盒」——引擎换比例时回调过来；
        // 回调可能不在主线程（自研内核），回主线程再动视图。
        surface.onScaleModeChanged = { [weak view] mode in
            Task { @MainActor in
                view?.setContentAspect(mode.forcedAspect)
            }
        }
        view.setContentAspect(surface.scaleMode.forcedAspect)
        return view
    }

    func updateNSView(_ view: LayerHostView, context: Context) {
        view.attach(surface.layer, sizedTo: size)
        view.setContentAspect(surface.scaleMode.forcedAspect)
    }
}
#endif
