import AVFoundation
import Combine
import Foundation

#if os(iOS)
import AVKit

/// 画中画（M27）—— 对齐参考播放器顶排那颗「画中画」。
///
/// 为什么 M27 才能做：系统内核的画面换成了自建的 `AVPlayerLayer` 宿主（``SystemVideoView``），
/// 起 PiP 只需要 `AVPictureInPictureController(playerLayer:)`（公开 API）。
/// MPV / 自研 FFmpeg 仍然不做（要一条逐帧拷贝层，M26 第六节的拍板）。
///
/// 三件事：
/// - **挂 / 拆**：`attach(layer:)` 在系统内核建起来时叫一次，`detach()` 在换内核 / 离开播放页时叫；
/// - **状态**：把「可不可能 / 是不是正在画中画」发布给播放页（顶排那颗按钮的可用态与图标跟着走）——
///   这两个属性都是 KVO 可观察的（Apple 官方的 PiP 自定义播放器样例就是盯它们）；
/// - **自动起**：`canStartPictureInPictureAutomaticallyFromInline` 打开 —— 切后台 / 按 Home 时
///   系统自己把 PiP 起出来（M26 第四批那套「后台出声 + 画中画」的体验由它接上）。
///
/// 拿不到就说拿不到：设备不支持（`isPictureInPictureSupported()` 为假）时 ``isSupported`` 为假，
/// 播放页那颗按钮整颗不出现（`docs/UI 规范.md` 第 5 条）。
@MainActor
final class PlaybackPipController: NSObject, ObservableObject {
    /// 这台设备 / 这个平台支不支持画中画。
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// 现在起不起得了（加载中 / 没有画面时为假）—— 按钮据此置灰。
    @Published private(set) var isPossible = false
    /// 是不是正在画中画（起 / 停都会更新，图标跟着翻）。
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var observations: [NSKeyValueObservation] = []

    /// 挂上画面层（重复挂同一个层也安全：先拆旧的）。
    func attach(layer: AVPlayerLayer) {
        detach()
        // 显式写成可选接收：这个初始化器在 SDK 上是 failable，写法在两种 SDK 签名下都编得过。
        let created: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: layer)
        guard let created else {
            return
        }
        created.canStartPictureInPictureAutomaticallyFromInline = true
        observations = [
            created.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                let active = controller.isPictureInPictureActive
                Task { @MainActor in
                    self?.note(possible: possible, active: active)
                }
            },
            created.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                let active = controller.isPictureInPictureActive
                Task { @MainActor in
                    self?.note(possible: possible, active: active)
                }
            },
        ]
        controller = created
    }

    /// 拆掉（换内核 / 离开播放页）：正在画中画就先停掉 —— 别让 PiP 挂在一个已经没了的内核上。
    func detach() {
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        observations = []
        controller = nil
        isPossible = false
        isActive = false
    }

    /// 起 / 停（顶排那颗按钮就这一个动作）。
    func toggle() {
        guard let controller else {
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    private func note(possible: Bool, active: Bool) {
        isPossible = possible
        isActive = active
    }
}

#else

/// 画中画（M27）：macOS 这一版不做（产品目标在 iOS）—— 类型留着让播放页的代码两端共用，
/// 那边 ``isSupported`` 为假、这颗按钮不出现（与「没有公开 API 的能力就不做」同一条规矩）。
@MainActor
final class PlaybackPipController: ObservableObject {
    static var isSupported: Bool { false }

    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    func attach(layer _: AVPlayerLayer) { }

    func detach() { }

    func toggle() { }
}

#endif
