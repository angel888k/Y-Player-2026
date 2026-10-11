@testable import CatVodUI
import Foundation
import Testing

/// 播放控制设置（M28）：默认值必须等于**上一版的行为**（回归基线），
/// 坏存档不许把播放页带进怪状态（认不出的动作 / 字段数不对一律整体回落）。
@Suite("播放控制设置")
struct PlaybackControlSettingsTests {
    /// 每个用例一个独立 suite：互不影响，也不会碰真实 App 的 UserDefaults。
    private func defaults() -> UserDefaults {
        let name = "yplayer.tests.control.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test("默认值 = M28 之前的行为：单击显隐、双击播放暂停、四条滑动与震动全开、步长 15 秒")
    func defaultsAreTheOldBehavior() {
        let settings = PlaybackControlSettings()
        #expect(settings.seekStepSeconds == 15)
        #expect(settings.showsControlCenter)
        #expect(settings.autoOpeningEnding)
        #expect(settings.singleTapCenter == .toggleControls)
        #expect(settings.singleTapSides == .toggleControls)
        #expect(settings.doubleTapCenter == .playPause)
        #expect(settings.doubleTapSides == .playPause)
        #expect(settings.swipeVolume)
        #expect(settings.swipeBrightness)
        #expect(settings.swipeSeek)
        #expect(settings.swipeEpisode)
        #expect(settings.hapticLongPress)
        #expect(settings.hapticBrightness)
        #expect(settings.hapticVolume)
        #expect(settings.hapticSeek)
    }

    @Test("存档往返：逐项存、逐项读回")
    func roundTrip() {
        let store = defaults()
        var settings = PlaybackControlSettings()
        settings.seekStepSeconds = 30
        settings.showsControlCenter = false
        settings.autoOpeningEnding = false
        settings.singleTapCenter = .playPause
        settings.singleTapSides = .none
        settings.doubleTapCenter = .seek
        settings.doubleTapSides = .toggleControls
        settings.swipeVolume = false
        settings.swipeBrightness = true
        settings.swipeSeek = false
        settings.swipeEpisode = false
        settings.hapticLongPress = false
        settings.hapticBrightness = true
        settings.hapticVolume = false
        settings.hapticSeek = false
        PlaybackControlBook.save(settings, defaults: store)
        #expect(PlaybackControlBook.load(defaults: store) == settings)
    }

    @Test("没有存档 → 默认")
    func emptyArchive() {
        #expect(PlaybackControlBook.load(defaults: defaults()) == PlaybackControlSettings())
    }

    @Test("坏存档：字段数不对 / 认不出的动作 / 非数字步长 —— 一律整体回落默认")
    func badArchive() {
        let store = defaults()
        let key = PlaybackControlBook.defaultsKey

        store.set("", forKey: key)
        #expect(PlaybackControlBook.load(defaults: store) == PlaybackControlSettings())

        store.set("15|1|1|1|1|2", forKey: key)
        #expect(PlaybackControlBook.load(defaults: store) == PlaybackControlSettings())

        // 四个动作位里任何一个认不出来（99）都整体回落
        store.set("15|1|1|99|1|2|2|1|1|1|1|1|1|1|1", forKey: key)
        #expect(PlaybackControlBook.load(defaults: store) == PlaybackControlSettings())

        // 步长不是数字
        store.set("abc|1|1|1|1|2|2|1|1|1|1|1|1|1|1", forKey: key)
        #expect(PlaybackControlBook.load(defaults: store) == PlaybackControlSettings())
    }

    @Test("步长夹紧：NaN 回默认，越界按大小夹（5...120）")
    func seekStepClamp() {
        #expect(PlaybackControlSettings.clampSeekStep(.nan) == 15)
        #expect(PlaybackControlSettings(seekStepSeconds: 3).seekStepSeconds == 5)
        #expect(PlaybackControlSettings(seekStepSeconds: 999).seekStepSeconds == 120)
        #expect(PlaybackControlSettings(seekStepSeconds: 60).seekStepSeconds == 60)
        // 存坏了也夹：读回来仍是能用的值
        let store = defaults()
        store.set("999|1|1|1|1|2|2|1|1|1|1|1|1|1|1", forKey: PlaybackControlBook.defaultsKey)
        #expect(PlaybackControlBook.load(defaults: store).seekStepSeconds == 120)
    }

    @Test("四个分区各回自己的字段（单击 / 双击 × 中间 / 两边）")
    func tapActionRouting() {
        var settings = PlaybackControlSettings()
        settings.singleTapCenter = .toggleControls
        settings.singleTapSides = .playPause
        settings.doubleTapCenter = .seek
        settings.doubleTapSides = .none
        #expect(settings.tapAction(doubleTap: false, isCenter: true) == .toggleControls)
        #expect(settings.tapAction(doubleTap: false, isCenter: false) == .playPause)
        #expect(settings.tapAction(doubleTap: true, isCenter: true) == .seek)
        #expect(settings.tapAction(doubleTap: true, isCenter: false) == .none)
    }

    @Test("可选动作四档都在、都有名字（设置页的菜单照它列）")
    func actionOptions() {
        #expect(PlaybackTapAction.options.count == 4)
        for action in PlaybackTapAction.options {
            #expect(!action.title.isEmpty)
        }
        #expect(PlaybackTapAction.options.contains(.toggleControls))
        #expect(PlaybackTapAction.options.contains(.seek))
    }

    @Test("震动刻度闸：第一次不震、同刻度不震、跨一格震、来回也震")
    func hapticTickGate() {
        var gate = PlaybackHapticTickGate()
        // 先把每次判定收进局部量再断言：`#expect` 会把表达式包进闭包，里面调 mutating 方法编不过
        // （M28 首验红在这里）。
        let first = gate.shouldTick(50)
        let same = gate.shouldTick(50)
        let up = gate.shouldTick(51)
        let sameAgain = gate.shouldTick(51)
        let back = gate.shouldTick(50)
        // 大跨度也算一次（拖动很快时不必补震中间那些格）
        let jump = gate.shouldTick(80)
        #expect(!first)
        #expect(!same)
        #expect(up)
        #expect(!sameAgain)
        #expect(back)
        #expect(jump)
    }

    @Test("三条刻度闸互不影响（亮度 / 音量 / 进度各记各的）")
    func hapticGatesAreIndependent() {
        var gates = PlaybackHapticGates()
        // 三条闸交错驱动（判定结果先收进局部量，理由同上一条）。
        let brightnessFirst = gates.shouldTickBrightness(0.30)
        let volumeFirst = gates.shouldTickVolume(1.00)
        let seekFirst = gates.shouldTickSeek(10)
        let brightnessSecond = gates.shouldTickBrightness(0.31)
        let volumeSecond = gates.shouldTickVolume(0.99)
        let seekSecond = gates.shouldTickSeek(11)
        // 原地不动的那两条不该被别的闸带响
        let brightnessAgain = gates.shouldTickBrightness(0.31)
        let seekAgain = gates.shouldTickSeek(11)
        #expect(!brightnessFirst)
        #expect(!volumeFirst)
        #expect(!seekFirst)
        #expect(brightnessSecond)
        #expect(volumeSecond)
        #expect(seekSecond)
        #expect(!brightnessAgain)
        #expect(!seekAgain)
    }
}

/// 播放页手势与设置的接线（M28）：分区判定复用「纵甩切集」那条，关掉的手势整次不做事。
///
/// `@MainActor`：`PlaybackView` 是 `@MainActor` 的，它的静态成员也在主 actor 上。
@Suite("播放页：手势开关与分区（M28）")
@MainActor
struct PlaybackControlWiringTests {
    @Test("落点分区：中间一半算中间、两侧四分之一算两边；拿不到落点按中间算")
    func centerTapZone() {
        #expect(PlaybackView.isCenterTap(startX: 500, width: 1000))
        #expect(PlaybackView.isCenterTap(startX: 250, width: 1000))
        #expect(PlaybackView.isCenterTap(startX: 750, width: 1000))
        #expect(!PlaybackView.isCenterTap(startX: 249, width: 1000))
        #expect(!PlaybackView.isCenterTap(startX: 751, width: 1000))
        #expect(PlaybackView.isCenterTap(startX: nil, width: 1000))
    }

    @Test("滑动开关：关掉哪条就只有哪条不做事")
    func dragEnabled() {
        let all = PlaybackControlSettings()
        #expect(PlaybackView.dragEnabled(.seek, settings: all))
        #expect(PlaybackView.dragEnabled(.brightness, settings: all))
        #expect(PlaybackView.dragEnabled(.volume, settings: all))

        var off = PlaybackControlSettings()
        off.swipeSeek = false
        off.swipeVolume = false
        #expect(!PlaybackView.dragEnabled(.seek, settings: off))
        #expect(PlaybackView.dragEnabled(.brightness, settings: off))
        #expect(!PlaybackView.dragEnabled(.volume, settings: off))
    }
}
