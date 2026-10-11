import SwiftUI

/// 带内存缓存的海报图（替换 `AsyncImage`；为什么换见 ``ImageLoader``）。
///
/// 与 `AsyncImage` 的差别（刻意的）：
/// - **命中缓存同步出图**：滚回去的卡片不闪占位、不再发请求；
/// - **按目标尺寸解码**：`targetSize`（像素）算得出来就按它下采样，主线程不碰原始大图；
/// - 失败只留占位色，不弹错（图挂了不该打断浏览）。
///
/// 尺寸的来源：外层 `.frame` 给定了就用 `targetSize`；给的是弹性宽度（网格）时用布局
/// 提议的 `size` 现算 —— 两者都是「像素」，由这里乘屏 scale。
struct CachedImage: View {
    /// 图片地址（空串 / 非法地址直接显示占位）。
    let url: String
    /// 目标显示尺寸（点）；nil = 用布局提议的尺寸现算（网格里弹性列用）。
    var targetSize: CGSize? = nil
    /// 内容缩放模式：海报铺满（默认）/ 频道图标等比放下。
    var contentMode: ContentMode = .fill

    /// 已经拿到的图。**必须有这个状态位**：缓存写在 `NSCache` 里、不是可观察对象，
    /// 图下回来了没人通知视图重画 —— 只靠「父视图碰巧重建」来显示，会一直空着
    /// （上机抓过：封面全不出来）。
    @State private var image: PlatformImage?
    @Environment(\.cachedImageLoader) private var loader
    /// 屏 scale（点 → 像素）。**不碰 `UIScreen.main`**：它从 iOS 16 起被弃用，
    /// 而且业务视图里的版本分支被 `check_lint.py` 的 platform_branch 拦（`docs/UI 规范.md` 第二节）。
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            let displaySize = pixelSize(proxy.size)
            Group {
                if let image {
                    imageView(image)
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .task(id: taskKey(displaySize)) {
                await load(displaySize)
            }
            // 到达合流（M28 首验之二十九）：一簇图一起下完时只在刷新的那一拍显示，
            // 不再「一张一个 `@State` → 一轮渲染」——那是滚动掉帧的元凶（帧账见的 55~110ms 停顿）。
            .task {
                for await _ in loader.arrival.subscribe() {
                    if let cached = loader.memory.cachedImage(for: url, targetSize: displaySize) {
                        image = cached
                    }
                }
            }
        }
    }

    private func imageView(_ image: PlatformImage) -> some View {
        PlatformImageView(image: image, contentMode: contentMode)
    }

    private func load(_ displaySize: CGSize) async {
        guard !url.isEmpty else {
            return
        }
        // 内存里已经有（滚动回收回来）就同步拿——不进 actor，不闪。
        if let cached = loader.memory.cachedImage(for: url, targetSize: displaySize) {
            image = cached
            return
        }
        do {
            let loaded = try await loader.image(for: url, targetSize: displaySize)
            image = loaded
            ImageLoadTrace.noteLoaded(url: url, size: displaySize)
        } catch {
            ImageLoadTrace.noteFailed(url: url, error: error)
        }
    }

    /// `.task(id:)` 的键：地址或尺寸变了就重新取（转屏后宽度会变）。
    private func taskKey(_ displaySize: CGSize) -> String {
        "\(url)#\(Int(displaySize.width))x\(Int(displaySize.height))"
    }

    /// 目标像素尺寸：外层指定优先，否则按布局提议的尺寸算。
    private func pixelSize(_ proposed: CGSize) -> CGSize {
        let scale = max(displayScale, 1)
        let size = targetSize ?? proposed
        return CGSize(
            width: max(size.width, 1) * scale,
            height: max(size.height, 1) * scale
        )
    }
}

// MARK: - 环境注入

/// 图片加载器（`RootView` 注入带沙盒目录的那份；预览 / 单测自动回落到 ``ImageLoader/shared``）。
private struct CachedImageLoaderKey: EnvironmentKey {
    static let defaultValue = ImageLoader.shared
}

extension EnvironmentValues {
    var cachedImageLoader: ImageLoader {
        get { self[CachedImageLoaderKey.self] }
        set { self[CachedImageLoaderKey.self] = newValue }
    }
}

extension View {
    /// 注入图片加载器（根视图用）。
    func cachedImageLoader(_ loader: ImageLoader) -> some View {
        environment(\.cachedImageLoader, loader)
    }
}
