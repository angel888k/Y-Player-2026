import SwiftUI

/// 「装得下就上宽版」的版本自适应容器（M28P7）。
///
/// 为什么需要它：全屏控制条底排有**两套版式** —— 宽版是那排文字按钮（播放器 / 字幕 / 视轨 /
/// 音轨 / 片头片尾 / 选集），窄版换成图标。原先切哪一套靠一条**估出来的宽度线**
/// （``PlaybackView/barCompactWidth``，按 iOS 系统字体量了个 ~541pt）：估的账只要有一处对不上
/// 就会翻车 —— 系统字体换了版本、用户开了大字号、macOS 上 `Menu` 自带下拉按钮的外壳（比 iOS
/// 标签宽一截）—— 于是「本该装得下」的宽版被挤：文字压扁 / 折行 / 行内间距散开（用户报
/// 「部分系统版本，全屏播放器的按钮排版不行」）。这里改成**按实测尺寸挑**：
///
/// | 系统 | 实现 |
/// | --- | --- |
/// | iOS 16+ / macOS 13+ | 原生 `ViewThatFits`：量一遍，挑第一版真装得下的 |
/// | iOS 15 | 没有这个 API —— 回落「按可用宽度对 ``threshold``」，与改之前一致 |
///
/// 与 `AdaptiveTap` / `AdaptiveZoom` / `AdaptiveNavigation` 同一套做法：
/// 版本分支集中在基础件里，业务视图不写 `#available`（`docs/UI 规范.md` 第二节）。
struct AdaptiveFitRow<Wide: View, Narrow: View>: View {
    /// 可用宽度（只有 iOS 15 那条回落路用得上）。
    let availableWidth: CGFloat
    /// 宽度线：`availableWidth >= threshold` 才上宽版（只有 iOS 15 那条回落路用得上）。
    let threshold: CGFloat
    /// 宽版（装得下时用）。
    @ViewBuilder let wide: () -> Wide
    /// 窄版（装不下时用的那一版）。
    @ViewBuilder let narrow: () -> Narrow

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            ViewThatFits(in: .horizontal) {
                wide()
                narrow()
            }
        } else if availableWidth >= threshold {
            wide()
        } else {
            narrow()
        }
    }
}
