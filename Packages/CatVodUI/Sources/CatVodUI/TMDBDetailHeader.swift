import CatVodSource
import Foundation
import SwiftUI

/// TMDB 视图顶部的**全幅头部**（M11 第一片 + 全幅改造）：背景图铺满顶部、渐变压暗，
/// 标题与当前线路名叠在图上（参考图的样子）。简介与提示在页面正文里，不在这层。
///
/// 数据经 `AppModel.tmdbBundle(for:mode:)`（会话缓存 + 并发合流，与选集卡片**共用同一次刮削**），
/// **不把加载状态塞进 `VodDetailView`**：那片代码已经很大，而元信息是独立的一层 ——
/// 它拉不到也不该拖垮详情本身。
///
/// 三态都明说，不静默：
/// - 拉到了 → 背景图（按 ``PosterMode``）+ 标题 + 线路名；
/// - 没配 key → 一行提示 + 站点自带的图片兜底；
/// - 拉失败 / 没搜到 → 一行原因，图仍用站点图片兜底。
struct TMDBDetailHeader: View {
    let model: AppModel
    /// 用来搜 TMDB 的片名（站点详情里的名字）。
    let title: String
    /// 站点自带的海报：TMDB 没结果时兜底，免得顶部空着。
    let fallbackPoster: String
    /// 当前线路名（参考图里叠在标题下面那行，如「115 原画」）。
    let lineName: String
    /// 取图策略（顶部与卡片共用同一套，见 ``PosterPicker``）。
    let mode: PosterMode

    /// 全幅头图的宽高比（宽 : 高 = 1 : 1）—— 参考图里头图从顶铺到约屏宽那么高。
    ///
    /// 用比例而不是固定高度：iPad / 横屏下头图跟着宽度长，不会缩成一条。
    /// `.aspectRatio(_:contentMode: .fit)` 在 `ScrollView` 里给出的就是「宽度定高」。
    static let heroAspectRatio: CGFloat = 1

    @State private var posterSet: TMDBPosterSet?
    @State private var metadata: TMDBMetadata?
    @State private var noticeText = ""
    /// 轮播步进：每转一格 +1。
    @State private var step = 0
    /// 进页面定一次的随机种子 —— 每一步都换种子会变成闪烁的图（见 ``PosterPicker``）。
    @State private var seed = UInt64.random(in: 0 ..< UInt64.max)

    /// 轮播间隔（秒）。
    private let rotateInterval: TimeInterval = 6

    /// 重新拉取的触发键：片名或取图模式变了才重来（换源 / 设置里换模式都会变）。
    private var loadKey: String {
        // 手动匹配也进键（M11 片 5）：在「⋯」里选了新的一条，这里就该重拉。
        "\(title)|\(mode.rawValue)|\(model.tmdbMatchToken(for: title))"
    }

    var body: some View {
        // GeometryReader + 显式宽高：先前把 AsyncImage 交给 frame(maxHeight: .infinity)
        // 时它塌成了 0 高（顶部只剩一块黑），这里给死宽高，不给它自由发挥的机会。
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // 底：深灰。异步图没来时也有形状（与骨架同色），不会是一块纯黑。
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                if let url = posterURL, let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }
                // 底部融合：图往**页面底色**融（不是往死黑融）—— 浅色外观下是白、深色下是黑，
                // 与下面那截正文无缝接上。参考图里就是「图慢慢化进页面」，不是压一条黑边。
                LinearGradient(
                    stops: [
                        .init(color: PlatformShims.pageBackground.opacity(0), location: 0.45),
                        .init(color: PlatformShims.pageBackground.opacity(0.8), location: 0.8),
                        .init(color: PlatformShims.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                VStack(spacing: 6) {
                    Text(displayTitle)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
                    if !lineName.isEmpty {
                        Text(lineName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.95))
                            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    }
                    if !noticeText.isEmpty {
                        Text(noticeText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
        .aspectRatio(Self.heroAspectRatio, contentMode: .fit)
        .clipped()
        .task(id: loadKey) {
            await load()
            await rotate()
        }
    }

    /// 现在该显示哪张：TMDB 图集优先，其次站点海报。
    private var posterURL: String? {
        if let posterSet, let picked = posterSet.image(step: step, seed: seed) {
            return picked
        }
        return fallbackPoster.isEmpty ? nil : fallbackPoster
    }

    private var displayTitle: String {
        guard let metadata, !metadata.title.isEmpty else {
            return title
        }
        return metadata.title
    }

    private func load() async {
        guard !title.isEmpty else {
            return
        }
        // 重拉之前先清旧值：换源（片名变了）时旧元信息不能留在屏上。
        metadata = nil
        posterSet = nil
        noticeText = ""
        let outcome = await model.tmdbBundle(for: title, mode: mode)
        switch outcome {
        case let .found(bundle):
            metadata = bundle.metadata
            posterSet = bundle.posterSet
        case .disabled:
            noticeText = "元信息刮削已关（详情页「⋯」里可以打开）。"
        case .notConfigured:
            noticeText = "没填 TMDB api key —— 这一层不工作（设置 → 播放 → 播放页）。"
        case .notFound:
            noticeText = "TMDB 里没搜到「\(title)」，暂用站点的海报。"
        case let .failed(reason):
            noticeText = "元信息没取到：\(reason)"
        }
    }

    /// 轮播：等一个间隔、步进一步。只有 `.rotate` 且真有多张图时才转。
    private func rotate() async {
        while !Task.isCancelled, mode == .rotate, (posterSet?.urls.count ?? 0) > 1 {
            try? await Task.sleep(nanoseconds: UInt64(rotateInterval * 1_000_000_000))
            if Task.isCancelled {
                return
            }
            step += 1
        }
    }
}
