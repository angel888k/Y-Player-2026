@testable import CatVodUI
import Foundation
import Testing

/// 图片的字节层磁盘缓存（M28P4）：**拉到过就落盘**，重启后直接复用；容量有上限、清得掉。
/// 这一层存在的理由：`URLCache` 存不存由服务器的 `Cache-Control` 说了算，
/// 用户看到过「缓存管理里图片缓存一直是 0」。
@Suite("图片文件缓存（字节层）")
struct ImageFileCacheTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-imagefilecache-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("存的能读回来；没存过给 nil")
    func roundTrip() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageFileCache(directory: directory)

        await cache.store(Data(repeating: 0x41, count: 2048), for: "https://example.com/a.png")
        let readBack = await cache.data(for: "https://example.com/a.png")
        #expect(readBack?.count == 2048)
        #expect(await cache.data(for: "https://example.com/missing.png") == nil)
        #expect(await cache.byteCount() == 2048)
    }

    @Test("只按 URL 存字节：同一张图的两种目标尺寸共用一份（省掉第二次下载）")
    func sharedAcrossSizes() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageFileCache(directory: directory)

        await cache.store(Data(repeating: 0x42, count: 1024), for: "https://example.com/same.png")
        #expect(await cache.data(for: "https://example.com/same.png")?.count == 1024)
        #expect(await cache.byteCount() == 1024, "两种尺寸不该各存一份")
    }

    @Test("清空只删自己这类文件：URLCache 的库文件与别的残留都不动")
    func removeAllKeepsForeignFiles() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("Cache.db")
        try Data(repeating: 0x43, count: 128).write(to: foreign)

        let cache = ImageFileCache(directory: directory)
        await cache.store(Data(repeating: 0x44, count: 256), for: "https://example.com/b.png")

        await cache.removeAll()
        #expect(FileManager.default.fileExists(atPath: foreign.path), "URLCache 的东西不归它删")
        #expect(await cache.byteCount() == 0)
    }

    @Test("超容量按最久没读过的淘汰，且刚存的那份一定还在")
    func prunesOldest() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageFileCache(directory: directory, capacity: 1000)

        await cache.store(Data(repeating: 0x45, count: 600), for: "https://example.com/old.png")
        try? await Task.sleep(nanoseconds: 30_000_000)
        await cache.store(Data(repeating: 0x46, count: 600), for: "https://example.com/mid.png")
        try? await Task.sleep(nanoseconds: 30_000_000)
        await cache.store(Data(repeating: 0x47, count: 600), for: "https://example.com/new.png")

        #expect(await cache.byteCount() <= 1000, "总量要收进上限")
        #expect(await cache.data(for: "https://example.com/new.png") != nil, "刚存的不能被自己淘汰掉")
        #expect(await cache.data(for: "https://example.com/old.png") == nil, "最久没读的先走")
    }

    @Test("读会 touch：读过的旧文件不再是第一个被淘汰的")
    func readTouchesForLRU() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageFileCache(directory: directory, capacity: 1000)

        await cache.store(Data(repeating: 0x48, count: 600), for: "https://example.com/first.png")
        try? await Task.sleep(nanoseconds: 30_000_000)
        await cache.store(Data(repeating: 0x49, count: 600), for: "https://example.com/second.png")
        // 读一下「先存的那份」：它的时间戳变新，淘汰顺序跟着换。
        _ = await cache.data(for: "https://example.com/first.png")
        try? await Task.sleep(nanoseconds: 30_000_000)
        await cache.store(Data(repeating: 0x4A, count: 600), for: "https://example.com/third.png")

        #expect(await cache.data(for: "https://example.com/first.png") != nil, "读过的这份不该先被删")
        #expect(await cache.data(for: "https://example.com/second.png") == nil, "最久没读的这份先走")
    }
}
