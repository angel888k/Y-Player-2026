import Foundation
import os

/// 图片加载的排障日志（M28 首验之二十九）：哪张图下回来了、哪张挂了、挂在哪一步。
///
/// 为什么需要它：图这一路的毛病（封面全不出来 / 某几张一直空着）是**静默**的 ——
/// 界面上只表现为「灰着」，看不出是网络、解码还是缓存；这类必须能一条命令取全部。
/// 与 `LibavTrace` / `MpvTrace` 同一套：子系统 = App 的 bundle id，级别 `.notice`（debug 级不落盘）。
///
///     xcrun simctl spawn booted log show --last 2m --predicate 'subsystem == "com.YPlayer.cat"' --style compact | grep 图片加载
enum ImageLoadTrace {
    static let logger = Logger(subsystem: "com.YPlayer.cat", category: "image")

    /// 下回来了（尺寸是**像素**：点 × 屏 scale）。
    static func noteLoaded(url: String, size: CGSize) {
        logger.notice("图片加载：ok \(url, privacy: .public) @\(Int(size.width))x\(Int(size.height))")
    }

    /// 挂了（带具体错因：4xx / 解不出图 / 断网）。
    static func noteFailed(url: String, error: Error) {
        let reason = (error as? ImageLoadError).map(String.init(describing:)) ?? String(describing: error)
        logger.notice("图片加载：失败 \(url, privacy: .public)（\(reason, privacy: .public)）")
    }
}
