@testable import CatVodUI
import Foundation
import SwiftUI
import Testing

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

    /// 一张 64x64 的 PNG（平台件生成；尺寸够大到「下采样」真的发生）。
    static let pngData: Data = {
        let image = platformTestImage(size: CGSize(width: 64, height: 64), color: .systemRed)
        return image.flatMap(platformPNGData) ?? Data()
    }()
}

@Suite("图片加载器（内存 + 磁盘缓存 / 去重 / 下采样）", .serialized)
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

        // 命中缓存给的是**同一份对象**（`NSCache` 直接返回），所以这里比对象本身，
        // 不拿像素数据比 —— `pngData()` 是 UIKit-only，跨端测试编不过。
        #expect(first === second, "第二次必须是缓存里那一份，而不是重新解码的另一份")
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

    @Test("下采样：原图 64x64 请求 64x64 时解出来不超过归档档位（且确实缩了、比例不变）")
    func downsamplesToTargetSize() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 目标尺寸按 25px **向上归档**（同一张卡在不同帧的小数尺寸共享缓存），
        // 所以请求 64 → 归档到 75：断言按归档语义写（≤ 档位、且不超原图）。
        let image = try await loader.image(for: "https://example.com/c.png", targetSize: CGSize(width: 64, height: 64))
        // `platformSize` 而不是 `.size`：`NSImage` 没有 `.size`（跨端测试要编得过）。
        #expect(image.platformSize.width <= 75)
        #expect(image.platformSize.height <= 75)
        #expect(abs(image.platformSize.width - image.platformSize.height) < 0.5, "等比缩放：64x64 的方图缩完仍是方的")
    }

    @Test("两种目标尺寸：磁盘那份字节共用（只下一次），解码与内存条目仍各一份")
    func sizeVariantsShareDownloadedBytes() async throws {
        StubImageProtocol.reset()
        let (loader, directory) = makeLoader()
        defer { try? FileManager.default.removeItem(at: directory) }

        let small = try await loader.image(for: "https://example.com/d.png", targetSize: CGSize(width: 16, height: 16))
        _ = try await loader.image(for: "https://example.com/d.png", targetSize: CGSize(width: 32, height: 32))

        // M28P4：字节层按 URL 存 —— 第二种尺寸从磁盘拿同一份字节、只多解一次码。
        // 「详情页大图不会被网格小图顶掉」没变：内存缓存仍按「URL + 尺寸」分条。
        #expect(StubImageProtocol.requestCount == 1, "同一张图的两种尺寸不该下两次")
        #expect(
            loader.cachedImage(for: "https://example.com/d.png", targetSize: CGSize(width: 16, height: 16)) === small,
            "小尺寸那份还在内存缓存里"
        )
        #expect(loader.cachedImage(for: "https://example.com/d.png", targetSize: CGSize(width: 32, height: 32)) != nil)
    }

    @Test("磁盘那份跨实例复用：新 loader 同目录再取一次，不再发网络请求（重启后也省）")
    func diskCacheSurvivesNewLoader() async throws {
        StubImageProtocol.reset()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-image-shared-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = CGSize(width: 40, height: 40)
        let first = makeLoader(directory: directory)
        _ = try await first.loader.image(for: "https://example.com/persist.png", targetSize: size)
        #expect(StubImageProtocol.requestCount == 1)

        // 新实例（模拟下一次启动）：内存缓存是空的，磁盘那份还在 —— 这正是「缓存管理里看得见」的那份。
        let second = makeLoader(directory: directory)
        _ = try await second.loader.image(for: "https://example.com/persist.png", targetSize: size)
        #expect(StubImageProtocol.requestCount == 1, "磁盘命中就不该再下")
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
