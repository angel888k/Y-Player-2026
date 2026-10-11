import AVFoundation
@testable import CatVodPlayer
import Testing

/// 系统内核的画面层（M27）：换掉 `AVKit.VideoPlayer` 之后的自建宿主 —— 层、播放器、画面比例三件事。
///
/// `@MainActor`：`AVPlayerEngine` 是主 actor 类（iOS 18 起 `AVPlayer` 受主线程约束），
/// 建引擎与读画面层都得在主 actor 上。
@MainActor
@Suite("系统内核：画面层（M27）")
struct SystemVideoSurfaceTests {
    @Test("引擎建出来时，画面层已经挂上了它自己的播放器")
    func engineWiresLayer() {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        #expect(engine.videoSurface.layer.player === engine.systemPlayer())
        engine.finishEvents()
    }

    @Test("画面比例：设一档就落到 videoGravity；映射不出来的档位保持原样")
    func gravityApplies() {
        let surface = SystemVideoSurface()
        surface.setScaleMode(.crop)
        #expect(surface.layer.videoGravity == .resizeAspectFill)
        surface.setScaleMode(.stretch)
        #expect(surface.layer.videoGravity == .resize)
        // 16:9 表达不了：不动它（不静默改成「适应」）。
        surface.setScaleMode(.ratio16x9)
        #expect(surface.layer.videoGravity == .resize)
    }

    @Test("引擎的 setScaleMode 真的写到这层上（界面那颗「画面比例」按钮走的就是这条路）")
    func engineAppliesScale() async {
        let engine = AVPlayerEngine(decoderMode: .hardware)
        await engine.setScaleMode(.crop)
        #expect(engine.videoSurface.layer.videoGravity == .resizeAspectFill)
        engine.finishEvents()
    }
}
