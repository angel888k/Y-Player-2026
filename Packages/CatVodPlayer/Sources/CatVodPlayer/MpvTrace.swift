import os

/// MPV 内核的排障日志（M27 首验之六之十起）：与 ``LibavTrace`` 同一套（子系统 = App 的 bundle id）。
///
/// 谁在用：``MpvEngine/setVideoAreaSize(_:)`` —— 画面区尺寸一变就记一条
/// 「转给 mpv 多大 + mpv 自己认的 `osd-dimensions`」，用来判定「mpv 到底按多大在画」。
enum MpvTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "mpv")
}
