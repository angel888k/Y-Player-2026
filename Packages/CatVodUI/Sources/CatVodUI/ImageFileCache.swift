import CatVodCore
import Foundation

/// 图片的**字节层**磁盘缓存（M28P4）：拉到的原始字节按 URL 落盘，重启后直接复用。
///
/// 为什么要单独一层（用户报「缓存管理里看不到图片缓存」）：HTTP 那层交给 `URLCache`，
/// 而**它存不存由服务器的 `Cache-Control` 说了算** —— `no-store` / `private` / 压根没给缓存头的
/// 图床，一张都不会落到盘上（上游图床里这种不少）。于是「缓存管理 → 图片缓存」长期是 0：
/// 看着像坏了，实际是没人替我们存。这一层不看服务器脸色：**拉到过就落盘**，
/// 缓存管理按目录算得到它、也删得掉（与首页 / 节目单缓存同一套「看得见、清得掉」）。
///
/// 与内存缓存的分工：内存那份存**解码后**的图（按「URL + 目标尺寸」），这里存**原始字节**
/// （只按 URL）—— 同一张图给两种尺寸用时只下一次、解两次（尺寸仍各自成条，见 ``ImageLoader``）。
actor ImageFileCache {
    /// 落盘目录（与 `URLCache` 同一个目录：缓存管理按它算「图片缓存」的大小）。
    private let directory: URL
    /// 容量上限（字节）：超了先删**最久没读过**的（读的时候会 touch 一份时间戳）。
    private let capacity: Int64
    private let fileManager = FileManager.default

    /// 自己的文件后缀：清空只删自己这类文件，`URLCache` 的库文件与别的残留都不碰。
    static let fileExtension = "img"

    /// - Parameters:
    ///   - directory: 落盘目录（`AppModel.imageCacheDirectory`）；
    ///   - capacity: 容量上限，默认 256 MB（与 `URLCache` 的磁盘上限一个量级）。
    init(directory: URL, capacity: Int64 = 256 * 1024 * 1024) {
        self.directory = directory
        self.capacity = capacity
    }

    /// 命中就读字节（并 touch，给淘汰用）；没有 / 读不出来返回 nil。
    func data(for url: String) -> Data? {
        let fileURL = fileURL(for: url)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return data
    }

    /// 落盘（原子写）；写不上不算错（下次再下）。
    func store(_ data: Data, for url: String) {
        guard !data.isEmpty else {
            return
        }
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fileURL = fileURL(for: url)
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else {
            return
        }
        pruneIfNeeded()
    }

    /// 删掉这一个 URL 的那份（字节坏了 —— 解不出图 —— 时用）。
    func remove(url: String) {
        try? fileManager.removeItem(at: fileURL(for: url))
    }

    /// 清空**本层**的文件。
    func removeAll() {
        for file in files() {
            try? fileManager.removeItem(at: file.url)
        }
    }

    /// 当前占用（单测 / 诊断用）。
    func byteCount() -> Int64 {
        files().reduce(0) { $0 + $1.size }
    }

    // MARK: - 文件名与淘汰

    /// 文件名：`<md5(url)>.img`（与仓库里别的缓存同一种命名习惯）。
    private func fileURL(for url: String) -> URL {
        directory.appendingPathComponent(MD5.hexDigest(of: Data(url.utf8)) + "." + Self.fileExtension)
    }

    /// 本层的文件清单（带大小与修改时间）。
    private func files() -> [(url: URL, size: Int64, modifiedAt: Date)] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        ) else {
            return []
        }
        return entries.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else {
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    /// 超容量：按「最久没读过」先删，直到装得下。
    private func pruneIfNeeded() {
        let entries = files()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > capacity else {
            return
        }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard total > capacity else {
                break
            }
            if (try? fileManager.removeItem(at: entry.url)) != nil {
                total -= entry.size
            }
        }
    }
}
