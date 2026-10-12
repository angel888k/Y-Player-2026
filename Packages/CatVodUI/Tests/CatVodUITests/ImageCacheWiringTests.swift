@testable import CatVodUI
import Foundation
import Testing

/// 图片缓存接进「缓存管理」（M28 首验之二十九）：占用算得进「全部缓存」、清得掉 ——
/// 缓存管理页那两行的**数据面**（页面上只是把这两个调用接到按钮上）。
@Suite("缓存管理：图片缓存")
@MainActor
struct ImageCacheWiringTests {
    @Test("临时目录里写两处文件：占用按文件合计；清空后目录还在、占用归零")
    func byteCountAndClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-imagecache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 1024).write(to: directory.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 512).write(to: directory.appendingPathComponent("nested/b.bin"))

        #expect(AppModel.directoryByteCount(at: directory) == 1536)

        let removed = AppModel.removeContents(of: directory)
        #expect(removed == 2)
        #expect(AppModel.directoryByteCount(at: directory) == 0)
        #expect(FileManager.default.fileExists(atPath: directory.path), "目录本身要留着 —— URLCache 还挂在它上面")
    }

    @Test("目录不存在：占用算 0、清理算 0（不报错）")
    func missingDirectoryIsSafe() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("yplayer-imagecache-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(AppModel.directoryByteCount(at: missing) == 0)
        #expect(AppModel.removeContents(of: missing) == 0)
    }

    @Test("接线：AppModel 的图片缓存目录在缓存根下，清空（含内存）返回删除数")
    func modelWiring() async throws {
        let fixture = try AppModelFixture()
        defer { fixture.tearDown() }
        let model = fixture.model

        #expect(model.imageCacheDirectory.lastPathComponent == "Images")
        #expect(model.imageCacheDirectory.deletingLastPathComponent().path == model.cacheDirectory.path)

        try FileManager.default.createDirectory(at: model.imageCacheDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 700).write(to: model.imageCacheDirectory.appendingPathComponent("c.bin"))
        #expect(model.imageCacheByteCount >= 700, "目录里应当能看到这份数据")
        #expect(model.clearableImageCacheByteCount >= 700, "「可清占用」要算上图片数据")

        #expect(await model.clearImageCache() >= 1)
        // 断言的是**可清占用**：`URLCache` 自己的库文件（几十 KB，`Cache.db`）保留不清 ——
        // 清它没用（下次访问还会重建），也不该出现在「图片缓存数据」那一行里。
        #expect(model.clearableImageCacheByteCount == 0)
    }
}
