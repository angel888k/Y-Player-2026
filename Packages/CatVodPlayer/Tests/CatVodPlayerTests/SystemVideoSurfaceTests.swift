import AVFoundation
@testable import CatVodPlayer
import Testing

/// 系统内核的画面层（M27）：换掉 `AVKit.VideoPlayer` 之后的自建宿主 —— 层、播放器、画面比例三件事。
///
/// `@MainActor`：`AVPlayerEngine` 是主 actor 类（iOS 18 起 `AVPlayer` 受主线程约束），
/// 建引擎与读画面层都得在主 actor 上。
@MainActor
@Suite("系统内核：画面层（M27）"), .enabled(if: VideoStackAvailability.isUsable, "CI 跳过：GitHub 运行器没有硬件视频栈")
struct SystemVideoSurfaceTests {
    @Test("引擎建出来时，画面层已经挂上了它自己的播放器")
    func engineWiresLayer() {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        #expect(engine.videoSurface.layer.player === engine.systemPlayer())
        engine.finishEvents()
    }

    @Test("画面比例：三态落到 videoGravity；比例档固定 resize 并回调（内容盒由界面层摆）")
    func gravityApplies() {
        let surface = SystemVideoSurface()
        var notified: [PlaybackScaleMode] = []
        surface.onScaleModeChanged = { notified.append($0) }
        surface.setScaleMode(.crop)
        #expect(surface.layer.videoGravity == .resizeAspectFill)
        surface.setScaleMode(.stretch)
        #expect(surface.layer.videoGravity == .resize)
        // 比例档：gravity 单独表达不了 —— 固定 resize（内容盒由界面层按 `forcedAspect` 摆）。
        surface.setScaleMode(.ratio16x9)
        #expect(surface.layer.videoGravity == .resize)
        #expect(notified == [.crop, .stretch, .ratio16x9])
        #expect(surface.scaleMode == .ratio16x9)
    }

    @Test("引擎的 setScaleMode 真的写到这层上（界面那颗「画面比例」按钮走的就是这条路）")
    func engineAppliesScale() async {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        await engine.setScaleMode(.crop)
        #expect(engine.videoSurface.layer.videoGravity == .resizeAspectFill)
        engine.finishEvents()
    }
}
