import SwiftUI

#if os(iOS)
import AVKit
#endif

/// 投屏（AirPlay 路由选择器，M27 首验之三）—— 对齐参考播放器顶排第二颗。
///
/// **只有系统内核有公开 API 能做**：`AVRoutePickerView` 走的是系统音频路由 + `AVPlayer` 的外部播放。
/// M26 第七节的投屏结论不变（DLNA 不做、自绘内核也没有公开的路：MPV / 自研 FFmpeg 既没有
/// AirPlay 的公开接口，DLNA 又卡 multicast 权利）—— 但这颗是**系统内核原先就有的能力**：
/// 它原来长在系统播放器自带的控件里，M27 换自建宿主之后那颗没了，这里把它接回来。
/// 拿不到（macOS）就整颗不出现（UI 规范第 5 条）。
enum PlaybackCast {
    static var isSupported: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

#if os(iOS)
/// `AVRoutePickerView` 的 SwiftUI 包装：它自己画那颗 AirPlay 图标、自己弹路由面板。
struct PlaybackCastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        // 视频播放：路由列表优先列能放视频的设备（iOS 13+ 的公开开关）。
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}
#else
/// macOS 这一版不做（产品目标在 iOS）；类型留着让顶排的代码两端共用。
struct PlaybackCastButton: View {
    var body: some View {
        EmptyView()
    }
}
#endif
