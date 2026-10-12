import SwiftUI

/// 带内存缓存的海报图（替换 `AsyncImage`；为什么换见 ``ImageLoader``）。
///
/// 与 `AsyncImage` 的差别（刻意的）：
/// - **命中缓存同步出图**：滚回去的卡片不闪占位、不再发请求；
/// - **按目标尺寸解码**：`targetSize`（像素）算得出来就按它下采样，主线程不碰原始大图；
/// - 失败只留占位色，不弹错（图挂了不该打断浏览）。
///
/// 尺寸的来源（**刻意不用 `GeometryReader`**）：`targetSize`（点）+ `aspectRatio` 直接算像素 ——
/// 网格里几十个 `GeometryReader` 会让布局每帧重解、主线程整段被占（上机帧账抓过：光滑动就
/// 单帧 100~170ms；`GeometryReader` 在懒容器里的已知代价）。海报本来就是定比盒子，
/// 给比例就够、不必量。
struct CachedImage: View {
    /// 图片地址（空串 / 非法地址直接显示占位）。
    let url: String
    /// 目标显示尺寸（点）：宽度必给；高度不给就按 `aspectRatio` 算。
    var targetSize: CGSize?
    /// 目标宽高比（宽 ÷ 高）：只用来把 `targetSize` 补全成完整盒子（下采样按最大边，多算无妨）。
    var aspectRatio: CGFloat = 2.0 / 3.0
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
        let displaySize = pixelSize(targetSize)
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
        // 不再「一张一个 `@State` → 一轮渲染」。
        .task {
            for await _ in loader.arrival.subscribe() {
                if let cached = loader.memory.cachedImage(for: url, targetSize: displaySize) {
                    image = cached
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

    /// 目标像素尺寸：`targetSize`（点）补全成完整盒子后乘屏 scale。
    ///
    /// 高度没给就按 `aspectRatio` 算 —— 下采样按最大边，多算的那点不影响观感、
    /// 只让缓存键更稳定（同一张卡在不同帧不会各算一份）。
    private func pixelSize(_ size: CGSize?) -> CGSize {
        let scale = max(displayScale, 1)
        let width = max(size?.width ?? Self.placeholderWidth, 1)
        let height = max(size?.height ?? (width / max(aspectRatio, 0.05)), 1)
        return CGSize(width: width * scale, height: height * scale)
    }

    /// 没给尺寸时的兜底宽度（点）：正常调用点都会明文给，这里只是不让除零。
    static let placeholderWidth: CGFloat = 120
}

extension EnvironmentValues {
    @Entry var cachedImageLoader: ImageLoader = .shared
}

extension View {
    /// 注入图片加载器（根视图用）。
    func cachedImageLoader(_ loader: ImageLoader) -> some View {
        environment(\.cachedImageLoader, loader)
    }
}
