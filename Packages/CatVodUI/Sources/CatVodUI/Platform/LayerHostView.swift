import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit

/// 挂任意 `CALayer` 的宿主视图（iOS）：把层按**画面区给的尺寸**铺满，尺寸变化时同步 `frame` 与 `contentsScale`。
///
/// 谁在用：``SystemVideoView``（AVPlayerLayer）/ ``MpvVideoView``（CAMetalLayer）/
/// ``FFmpegVideoView``（AVSampleBufferDisplayLayer）—— 三个内核的宿主逻辑一模一样，就这一份。
///
/// **尺寸由 SwiftUI 明文递进来**（见 ``attach(_:sizedTo:)``）：`UIViewRepresentable` 的尺寸只在
/// 「视图的值变了」时才更新，而 `surface` 在布局变化（就地放大 / 转屏 / 分屏）时并不变 ——
/// 光靠框架提议，宿主会一直停在**创建那一刻**的大小上（M27 首验之六：画面区都铺满整屏了，
/// 画面还是旧槽位那么大、还锚在左上角，点屏幕别处也没反应）。
final class LayerHostView: UIView {
    private weak var attachedLayer: CALayer?
    /// SwiftUI 画面区量出来的尺寸；nil = 还没递进来（这时按 `bounds` 走）。
    private var hostedSize: CGSize?
    /// 复查层的任务（只有一次，新的来了就换掉）。
    private var verifyTask: Task<Void, Never>?

    /// 挂层 + 明确尺寸（`size` 来自画面区的 `GeometryReader`）。
    func attach(_ layer: CALayer, sizedTo size: CGSize) {
        // 跟着容器长（与下面 `sizeThatFits` 同一条理由）：容器换了尺寸，宿主自己跟上。
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer.addSublayer(layer)
            attachedLayer = layer
        }
        let changed = hostedSize != size
        hostedSize = size
        resize(to: size)
        syncFrame()
        if changed {
            // 尺寸真的变了才记一条：`attach` 每次更新都会被调到（见 ``VideoHostTrace``）。
            VideoHostTrace.noteHostSize(size, frame: frame, layerFrame: attachedLayer?.frame)
            scheduleLayerCheck()
        }
    }

    /// 过一秒复查层还在不在我们这儿（见 ``VideoHostTrace/noteLayerCheck(attached:frame:)``）——
    /// 画中画会把层搬走，那时「画面缩在一角」跟尺寸无关，得靠这条分清。
    private func scheduleLayerCheck() {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else {
                return
            }
            let layer = attachedLayer
            VideoHostTrace.noteLayerCheck(
                attached: layer?.superlayer === self.layer,
                frame: layer?.frame,
                layerBounds: layer?.bounds,
                presentationBounds: layer?.presentation()?.bounds,
                contentsGravity: layer?.contentsGravity.rawValue,
                identityTransform: layer.map { CATransform3DIsIdentity($0.transform) },
                windowFrame: window.map { convert(bounds, to: $0) },
                windowSize: window?.bounds.size
            )
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncFrame()
    }

    /// **提议多大就是多大**（M27 首验之六）。
    ///
    /// 不写这条会出事：`UIView.sizeThatFits(_:)` 的默认实现返回**视图已有的尺寸** ——
    /// SwiftUI 拿它当「这个宿主想要多大」，布局一变（就地放大 / 转屏 / 分屏）画面就停在上一个尺寸上。
    ///
    /// 宿主对尺寸没有任何主张：它只负责把层铺满画面区 —— 提议多大就是多大
    /// （拿不到有限值时退回当前尺寸，别把无穷大传出去）。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        Self.finite(size) ?? bounds.size
    }

    /// 自己挪到画面区的位置、撑到画面区的大小 —— SwiftUI 那边**不一定**给我们补这一下
    /// （它只在「视图的值变了」时才更新），所以两层都写：值里带尺寸（`updateUIView` 因此会被调到）
    /// + 这里显式定 frame。
    private func resize(to size: CGSize) {
        guard let size = Self.finite(size) else {
            return
        }
        let target = CGRect(origin: .zero, size: size)
        if frame != target {
            frame = target
        }
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        // 关掉隐式动画：尺寸变化时不做动画，否则画面会拖影。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let target = CGRect(origin: .zero, size: hostedSize ?? bounds.size)
        if attachedLayer.frame != target {
            attachedLayer.frame = target
            // 尺寸真的变了：**把层重新挂一次**。`AVPlayerLayer` 的渲染几何是挂上去那一刻跟
            // `player` 绑定的 —— 只改 frame 不重挂，画面会一直按旧尺寸画（M27 首验之六之七：
            // 层 / 宿主 / 窗口三处都是 874×402，屏幕上却还是竖屏槽位那么小一块；暂停能暂停，
            // 说明确实是这一路播放）。
            attachedLayer.removeFromSuperlayer()
            layer.addSublayer(attachedLayer)
        }
        attachedLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
        CATransaction.commit()
    }

    /// 只认「正的、有限的」尺寸；拿不到回 nil，让调用方退回旧值。
    private static func finite(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }
}

#else
import AppKit

/// 挂任意 `CALayer` 的宿主视图（macOS）：与 iOS 那份同一套约定（尺寸明文递进来，见 `attach`）。
final class LayerHostView: NSView {
    private weak var attachedLayer: CALayer?
    private var hostedSize: CGSize?
    /// 复查层的任务（只有一次，新的来了就换掉）。
    private var verifyTask: Task<Void, Never>?

    func attach(_ layer: CALayer, sizedTo size: CGSize) {
        autoresizingMask = [.width, .height]
        if attachedLayer !== layer {
            attachedLayer?.removeFromSuperlayer()
            self.layer?.addSublayer(layer)
            attachedLayer = layer
        }
        let changed = hostedSize != size
        hostedSize = size
        resize(to: size)
        syncFrame()
        if changed {
            // 尺寸真的变了才记一条：`attach` 每次更新都会被调到（见 ``VideoHostTrace``）。
            VideoHostTrace.noteHostSize(size, frame: frame, layerFrame: attachedLayer?.frame)
            scheduleLayerCheck()
        }
    }

    /// 过一秒复查层还在不在我们这儿（见 ``VideoHostTrace/noteLayerCheck(attached:frame:)``）。
    private func scheduleLayerCheck() {
        verifyTask?.cancel()
        verifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else {
                return
            }
            let layer = attachedLayer
            // AppKit 这边没有 `UIWindow` 那套：`NSWindow` 不是 `NSView`，`convert(_:to:)` 只认视图 ——
            // 拿它的 `contentView` 当坐标系（iOS 那边窗口本身就是视图，直接用）。
            VideoHostTrace.noteLayerCheck(
                attached: layer?.superlayer === self.layer,
                frame: layer?.frame,
                layerBounds: layer?.bounds,
                presentationBounds: layer?.presentation()?.bounds,
                contentsGravity: layer?.contentsGravity.rawValue,
                identityTransform: layer.map { CATransform3DIsIdentity($0.transform) },
                windowFrame: window?.contentView.map { convert(bounds, to: $0) },
                windowSize: window?.contentView?.bounds.size
            )
        }
    }

    override func layout() {
        super.layout()
        syncFrame()
    }

    private func resize(to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return
        }
        let target = CGRect(origin: .zero, size: size)
        if frame != target {
            frame = target
        }
    }

    private func syncFrame() {
        guard let attachedLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let target = CGRect(origin: .zero, size: hostedSize ?? bounds.size)
        if attachedLayer.frame != target {
            attachedLayer.frame = target
            // 尺寸变了就重挂一次（理由见 iOS 那一支的注释）。
            attachedLayer.removeFromSuperlayer()
            layer?.addSublayer(attachedLayer)
        }
        attachedLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
#endif
