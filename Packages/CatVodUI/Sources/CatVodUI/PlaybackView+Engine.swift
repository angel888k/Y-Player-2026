import CatVodPlayer
import SwiftUI

/// 播放页的「就地换内核」（M26：对齐参考底排那颗「播放器」）。
///
/// 为什么要拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint `file_length` 的 error 线（800）——
/// 与 `+Controls` / `+Gestures` / `+Speed` / `+Stats` 同一套做法；跨文件用到的成员本来就是模块内。
extension PlaybackView {
    /// 当前生效的播放设置：内核取 ``engineKind``（可被控制条就地换掉），解码方式照设置。
    var effectiveSettings: PlaybackSettings {
        var copy = settings
        copy.engine = engineKind
        return copy
    }

    /// 就地换内核（M26：对齐参考底排那颗「播放器」）：**先落位置 → 拆旧内核 → 从同一位置接着播**。
    ///
    /// 只换内核，别的偏好不动 —— 倍速 / 画面比例 / 音量增益 / 轨道选择在 `start()` 里按界面态重套；
    /// 续播位置来自进度记录（`resumableResource()`），换前先 `persist(force: true)` 写一次。
    /// 不可用的内核不会出现在菜单里（`PlayerEngineKind/isAvailable`），这里也不自动降级。
    func switchEngine(to kind: PlayerEngineKind) async {
        guard kind != engineKind else {
            return
        }
        await persist(force: true)
        let previous = engine
        engine = nil
        systemSurface = nil
        pipController.detach()
        mpvSurface = nil
        ffmpegSurface = nil
        eventTask?.cancel()
        eventTask = nil
        await previous?.finishEvents()
        await previous?.teardown()
        engineKind = kind
        onEngineChanged?(kind)
        await start()
    }

    /// 重试一次播放（M16P8）：引擎已经建起来就重新 load，没建起来就整条 `start()` 重走。
    func retryPlayback() async {
        errorText = ""
        if engine == nil {
            await start()
        } else {
            await loadActiveResource()
        }
    }
}
