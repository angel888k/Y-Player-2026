import SwiftUI

/// 单击 / 双击的**组合**（双击优先），并把**落点**给出来 —— 播放页按落点分「中间一半 / 两侧」
/// 两档动作（M28 的「播放控制」）。
///
/// | 平台/版本 | 实现 | 落点 |
/// | --- | --- | --- |
/// | iOS 16+ / macOS 13+ | `SpatialTapGesture` | 有（`value.location`） |
/// | iOS 15 | `TapGesture`（该版本唯一的原生等价物） | 没有 —— 给 `nil`，调用方按「中间」那一档处理 |
///
/// **为什么不能用「旁听」手势去记落点**（M28 首验踩的，就是坑 28 那一类）：在画面层上再挂一条
/// 零距离拖动看着「只记位置、不参与动作」，可它照样进手势竞争 —— 轻则把点按吃掉（点屏幕没反应），
/// 重则把长按加速挂死（序列的 `onEnded` 不来，提示一直亮 `2.0x`）。
/// 落点这件事只能**由点按手势自己**给：`SpatialTapGesture` 有就吃，没有（iOS 15）就按主档处理。
/// 点按落点的能力位（设置页据此决定「屏幕两边」那两行摆不摆）。
///
/// iOS 15 没有 `SpatialTapGesture`，也就拿不到点按落点 —— 那边一律按「中间」那一档处理，
/// 「两边」这个可调项在 iOS 15 上不出现（不摆点了没反应的开关，`docs/UI 规范.md` 第 5 条）。
public enum AdaptiveTapShim {
    /// 点按能不能给出落点（iOS 16+ / macOS 13+）。
    public static let supportsTapLocation: Bool = {
        if #available(iOS 16.0, macOS 13.0, *) {
            return true
        }
        return false
    }()
}

public extension View {
    /// 挂一条「双击优先、单击随后」的点按组合；落点拿不到时给 `nil`。
    ///
    /// 两个回调的语义与 `exclusively(before:)` 那套一致：双击成立时单击**不**触发
    /// （单击只在「没有第二下」之后才来）。
    @ViewBuilder
    func adaptiveTapGesture(
        onDoubleTap: @escaping (CGPoint?) -> Void,
        onSingleTap: @escaping (CGPoint?) -> Void
    ) -> some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { onDoubleTap($0.location) }
                    .exclusively(
                        before: SpatialTapGesture(count: 1)
                            .onEnded { onSingleTap($0.location) }
                    )
            )
        } else {
            gesture(
                TapGesture(count: 2)
                    .onEnded { _ in onDoubleTap(nil) }
                    .exclusively(
                        before: TapGesture(count: 1)
                            .onEnded { _ in onSingleTap(nil) }
                    )
            )
        }
    }
}
