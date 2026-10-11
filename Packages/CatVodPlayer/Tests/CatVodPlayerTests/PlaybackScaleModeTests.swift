import AVFoundation
@testable import CatVodPlayer
import Foundation
import Testing

/// 画面比例（M03P9；M27 起系统内核也有一档）：支持矩阵、mpv 三条属性、两个 gravity 内核的映射，
/// 以及引擎真的下命令。
@Suite("画面比例")
struct PlaybackScaleModeTests {
    @Test("支持矩阵：三个内核都全支持（M28 首验之十九：比例档靠「内容盒 + resize」补齐）")
    func supportMatrix() {
        #expect(PlaybackScaleMode.supportedModes(by: .mpv) == PlaybackScaleMode.allCases)
        #expect(PlaybackScaleMode.supportedModes(by: .system) == PlaybackScaleMode.allCases)
        #expect(PlaybackScaleMode.supportedModes(by: .ffmpeg) == PlaybackScaleMode.allCases)
    }

    @Test("从存档串还原：认得出就用，空串 / 认不出回落「适应」（M03P19）")
    func decodeArchive() {
        #expect(PlaybackScaleMode.decode("crop") == .crop)
        #expect(PlaybackScaleMode.decode("ratio4x3") == .ratio4x3)
        #expect(PlaybackScaleMode.decode("") == .fit)
        #expect(PlaybackScaleMode.decode(nil) == .fit)
        #expect(PlaybackScaleMode.decode("zoom-in") == .fit)
        // 每一档都能往返（存档位就是 rawValue）
        for mode in PlaybackScaleMode.allCases {
            #expect(PlaybackScaleMode.decode(mode.rawValue) == mode)
        }
    }

    @Test("档位文案：对齐参考截图（M28 首验之十八），默认「适应屏幕」")
    func displayNames() {
        #expect(PlaybackScaleMode.fit.displayName == "适应屏幕")
        #expect(PlaybackScaleMode.crop.displayName == "裁剪全屏")
        #expect(PlaybackScaleMode.stretch.displayName == "拉伸全屏")
        #expect(PlaybackScaleMode.ratio4x3.displayName == "4:3")
        #expect(PlaybackScaleMode.ratio5x4.displayName == "5:4")
        #expect(PlaybackScaleMode.ratio16x9.displayName == "16:9")
        #expect(PlaybackScaleMode.ratio21x9.displayName == "21:9")
        #expect(PlaybackScaleMode.ratio239.displayName == "2.39:1")
        // 默认就是「适应屏幕」（fresh 记录 / 坏存档都落这一档）。
        #expect(PlaybackScaleMode.decode(nil) == .fit)
    }

    @Test("mpv：每一档都把三条属性设一遍（不留上一档的残留）")
    func mpvCommands() {
        for mode in PlaybackScaleMode.allCases {
            let commands = mode.mpvCommands
            #expect(commands.count == 3)
            #expect(commands.map { $0[1] } == ["video-aspect-override", "panscan", "keepaspect"])
            #expect(commands.allSatisfy { $0.count == 3 && $0[0] == "set" })
        }
        // 抽查几条关键值：16:9 只改比例；裁剪 = panscan 1 且仍保比例；拉伸 = keepaspect no。
        #expect(PlaybackScaleMode.ratio16x9.mpvCommands[0] == ["set", "video-aspect-override", "16:9"])
        #expect(PlaybackScaleMode.ratio5x4.mpvCommands[0] == ["set", "video-aspect-override", "5:4"])
        #expect(PlaybackScaleMode.ratio21x9.mpvCommands[0] == ["set", "video-aspect-override", "21:9"])
        #expect(PlaybackScaleMode.ratio239.mpvCommands[0] == ["set", "video-aspect-override", "2.39:1"])
        #expect(PlaybackScaleMode.crop.mpvCommands[1] == ["set", "panscan", "1.0"])
        #expect(PlaybackScaleMode.crop.mpvCommands[2] == ["set", "keepaspect", "yes"])
        #expect(PlaybackScaleMode.stretch.mpvCommands[2] == ["set", "keepaspect", "no"])
        #expect(PlaybackScaleMode.fit.mpvCommands[0] == ["set", "video-aspect-override", "no"])
    }

    @Test("gravity：三态有值；比例档映射不出来（nil —— 靠「内容盒 + resize」组合表达）")
    func avGravity() {
        #expect(PlaybackScaleMode.fit.avVideoGravity == .resizeAspect)
        #expect(PlaybackScaleMode.crop.avVideoGravity == .resizeAspectFill)
        #expect(PlaybackScaleMode.stretch.avVideoGravity == .resize)
        #expect(PlaybackScaleMode.ratio16x9.avVideoGravity == nil)
        #expect(PlaybackScaleMode.ratio4x3.avVideoGravity == nil)
        #expect(PlaybackScaleMode.ratio5x4.avVideoGravity == nil)
        #expect(PlaybackScaleMode.ratio21x9.avVideoGravity == nil)
        #expect(PlaybackScaleMode.ratio239.avVideoGravity == nil)
    }

    @Test("强制比例：五档给宽高比；前三档 nil（走 gravity 自己留边）")
    func forcedAspect() {
        #expect(PlaybackScaleMode.fit.forcedAspect == nil)
        #expect(PlaybackScaleMode.crop.forcedAspect == nil)
        #expect(PlaybackScaleMode.stretch.forcedAspect == nil)
        // 比数留容差：字面量在编译器里折出来的值可能和运行时差最后一位（交接坑 35）。
        func near(_ aspect: CGFloat?, _ expected: CGFloat) -> Bool {
            guard let aspect else {
                return false
            }
            return abs(aspect - expected) < 0.0001
        }
        #expect(near(PlaybackScaleMode.ratio4x3.forcedAspect, 4.0 / 3.0))
        #expect(near(PlaybackScaleMode.ratio5x4.forcedAspect, 5.0 / 4.0))
        #expect(near(PlaybackScaleMode.ratio16x9.forcedAspect, 16.0 / 9.0))
        #expect(near(PlaybackScaleMode.ratio21x9.forcedAspect, 21.0 / 9.0))
        #expect(near(PlaybackScaleMode.ratio239.forcedAspect, 2.39))
    }

    @Test("自研内核的画面层：三态落到 videoGravity；比例档固定 resize 并把回调打出去")
    func surfaceAppliesGravity() {
        let surface = FFmpegVideoSurface()
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

    @Test("MPV 引擎：load 之后 setScaleMode 真的把命令下给会话")
    func engineAppliesScale() async throws {
        let session = FakeMpvSession()
        let engine = MpvEngine(decoderMode: .hardware, makeSession: { session })
        try await engine.load(MediaResource(url: "https://example.com/live.m3u8"))

        await engine.setScaleMode(.crop)

        let commands = session.commands
        #expect(commands.contains(["set", "video-aspect-override", "no"]))
        #expect(commands.contains(["set", "panscan", "1.0"]))
        #expect(commands.contains(["set", "keepaspect", "yes"]))
    }

    @Test("MPV 引擎：还没 load（没有会话）时 setScaleMode 是安全空操作")
    func engineWithoutSessionIsSafe() async {
        let engine = MpvEngine(decoderMode: .hardware, makeSession: { nil })
        await engine.setScaleMode(.stretch)
        // Swift Testing 的宏参数里不写 await（本仓库踩过）：先落局部再断言。
        let state = await engine.currentState()
        #expect(state == .idle)
    }
}
