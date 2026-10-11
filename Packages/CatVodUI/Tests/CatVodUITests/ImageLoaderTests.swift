import Foundation
@testable import CatVodUI
import Testing
import UIKit

/// 桩 `URLProtocol`：拦下请求返回一张可解码的图，并**数请求次数**（缓存语义靠它验）。
final class StubImageProtocol: URLProtocol {
    /// 收到的请求数（所有用例共用，`reset()` 归零；`URLProtocol` 由系统实例化，只能用静态）。
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.pngData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    /// 一张 8x8 的 PNG（`UIGraphicsImageRenderer` 生成；尺寸小、解码快，适合单测）。
    static let pngData: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return image.pngData() ?? Data()
    }()
}

@Suite("图片加载器（内存 + 磁盘缓存 / 去重 / 下采样）")
struct ImageLoaderTests {
    /// 用临时目录建一个走桩协议的装载器（不走真网络、不碰真缓存目录）。
    private func makeLoader(directory: URL? = nil) -> (loader: ImageLoader, directory: URL) {
        let dir = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-image-\(UUID().uuidString)", isDirectory: true)
        let loader = ImageLoader(cacheDirectory: dir, protocolClasses: [StubImageProtocol.self])
        return (loader, dir)
    }

    @Test("第二次取同一张图走内存缓存：不再发网络请求，且拿到的是同一份解码结果")
    func memoryCacheAvoidsSecondRequest() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 40, height: 40)
        let first = try await loader.image(for: "https://example.com/a.png", targetSize: size)
        let second = try await loader.image(for: "https://example.com/a.png", targetSize: size)

        #expect(first.size == second.size)
        #expect(first.pngData() == second.pngData(), "同一张图两次解码结果必须一致（下采样参数稳定）")
        #expect(StubImageProtocol.requestCount == 1, "内存命中后不该再发请求 —— 这正是滚动回收时省下的那一次")
        let hits = await loader.memory.hitCount
        let misses = await loader.memory.missCount
        #expect(hits == 1)
        #expect(misses == 1)
    }

    @Test("同 URL 并发取图只发一次请求（在途合并）：横滑与网格同时命中时不能各下一份")
    func inFlightDeduplication() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 40, height: 40)
        async let a = loader.image(for: "https://example.com/b.png", targetSize: size)
        async let b = loader.image(for: "https://example.com/b.png", targetSize: size)
        async let c = loader.image(for: "https://example.com/b.png", targetSize: size)
        _ = try await (a, b, c)

        #expect(StubImageProtocol.requestCount == 1, "三个并发请求应该只对应一次下载")
    }

    @Test("下采样：原图 8x8 请求 4x4 时解出来的尺寸缩到目标内（且比例不变）")
    func downsamplesToTargetSize() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = try await loader.image(for: "https://example.com/c.png", targetSize: CGSize(width: 4, height: 4))
        #expect(image.size.width <= 4.5)
        #expect(image.size.height <= 4.5)
        #expect(abs(image.size.width - image.size.height) < 0.5, "等比缩放：8x8 的方图缩完仍是方的")
    }

    @Test("缓存键带尺寸：同一 URL 两种目标尺寸各自解码（详情页大图不会被网格小图顶掉）")
    func sizeVariantUsesSeparateCacheEntry() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await loader.image(for: "https://example.com/d.png", targetSize: CGSize(width: 16, height: 16))
        _ = try await loader.image(for: "https://example.com/d.png", targetSize: CGSize(width: 32, height: 32))

        #expect(StubImageProtocol.requestCount == 2, "两种尺寸是两条缓存条目，各发一次（这是有意的）")
    }

    @Test("清缓存：磁盘目录清空 + 内存缓存失效（下次重新走网络）")
    func clearEmptiesBothLayers() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 40, height: 40)
        _ = try await loader.image(for: "https://example.com/e.png", targetSize: size)
        #expect(StubImageProtocol.requestCount == 1)

        await loader.clear()

        _ = try await loader.image(for: "https://example.com/e.png", targetSize: size)
        #expect(StubImageProtocol.requestCount == 2, "清过缓存后必须重新下载（否则「清空」是假的）")
    }

    @Test("非法地址：给 invalidURL，不发请求")
    func invalidURLFailsFast() async {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: ImageLoadError.invalidURL) {
            _ = try await loader.image(for: "", targetSize: CGSize(width: 40, height: 40))
        }
        #expect(StubImageProtocol.requestCount == 0)
    }
}
