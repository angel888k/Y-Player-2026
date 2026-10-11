import Foundation

#if os(iOS)
import UIKit

/// 播放页的震动反馈（M28，对齐参考「震动反馈」那一组的四个开关）。
///
/// 只做「一下」级别的轻反馈，不惹眼也不费电：生成器现建现用（`prepare()` 提前热机换来的那点延迟，
/// 在「每跨 1% 震一下」这种尺度上听不出来）。三条刻度闸在 ``PlaybackHapticGates``（纯逻辑，有单测）——
/// 这里只管「震」，不管「什么时候该震」。
///
/// macOS 这一版不做（与画中画同一口径）：``isSupported`` 为假，设置页那一组整组不出现。
@MainActor
enum PlaybackHaptics {
    /// 这台设备 / 这个平台会不会震（设置页据此决定「震动反馈」那一组摆不摆）。
    static let isSupported = true

    /// 刻度反馈：亮度 / 音量跨 1%、进度跨 1 秒那一下。
    static func tick() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// 长按屏幕（识别到长按加速）那一下：比刻度重一档。
    static func press() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

#else

/// 播放页的震动反馈（M28）：macOS 这一版不做 —— ``isSupported`` 为假，调用方按「不做」处理。
@MainActor
enum PlaybackHaptics {
    static let isSupported = false

    static func tick() { }

    static func press() { }
}

#endif
