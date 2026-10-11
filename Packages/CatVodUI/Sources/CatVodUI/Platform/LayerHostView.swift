import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 挂任意 `CALayer` 的宿主视图（iOS）：铺满自己，尺寸变化时同步 `frame` 与 `contentsScale`。
///
/// 谁在用：``MpvVideoView``（CAMetalLayer）与 ``FFmpegVideoView``（AVSampleBufferDisplayLayer）——
/// 两边宿主逻辑一模一样，就这一份（M04P13 从 `MpvVideoView` 里提出来）。
final class LayerHostView: UIView {
    private weak var attachedLayer: CALayer?

    func attach(_ layer: CALayer) {
        // 跟着容器长（与下面 `sizeThatFits` 同一条理由）：SwiftUI 的容器换了尺寸，
        // 宿主自己跟上 —— 不指望谁再给我们补设一次 frame。
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer.addSublayer(layer)
            attachedLayer = layer
        }
        syncFrame()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncFrame()
    }

    /// **提议多大就是多大**（M27 首验之六）。
    ///
    /// 不写这条会出事：`UIView.sizeThatFits(_:)` 的默认实现返回**视图已有的尺寸** ——
    /// SwiftUI 拿它当「这个宿主想要多大」，于是布局变了（就地放大 / 转屏 / 分屏）之后，
    /// 画面还停在**旧槽位**那么大：用户截图里就是「黑屏一角挂着一小块画面」，
    /// 点屏幕别处还没反应（手势层只盖住那一小块）。
    ///
    /// 宿主对尺寸没有任何主张：它只负责把层铺满画面区 —— 提议多大就是多大
    /// （拿不到有限值时退回当前尺寸，别把无穷大传出去）。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? size.width : bounds.width,
            height: size.height.isFinite ? size.height : bounds.height
        )
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        // 关掉隐式动画：尺寸变化时不做动画，否则画面会拖影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer.frame = bounds
        attachedLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
    }
}

#else
import AppKit

/// 挂任意 `CALayer` 的宿主视图（macOS）。
final class LayerHostView: NSView {
    private weak var attachedLayer: CALayer?

    func attach(_ layer: CALayer) {
        // 跟着容器长：SwiftUI 的容器换了尺寸，宿主自己跟上（iOS 那边另有 `sizeThatFits`；
        // 这里没有对应物，靠这条 + `layout()` 兜住）。
        autoresizingMask = [.width, .height]
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
            attachedLayer = layer
        }
        syncFrame()
    }

    override func layout() {
        super.layout()
        syncFrame()
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        attachedLayer.frame = bounds
        attachedLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
#endif
