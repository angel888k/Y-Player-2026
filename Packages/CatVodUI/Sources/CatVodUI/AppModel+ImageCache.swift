import CatVodCore
import CatVodSource
import Foundation

// 「设置 → 数据 → 缓存管理」的图片缓存接线（M28 首验之二十九）。
//
// 图片缓存与首页/源/节目单缓存同根（`cacheDirectory/Images`）：设置页的「全部缓存」把它算进去、
// 单独一行能看大小、能清掉 —— 用户口径：缓存都要能在缓存管理里看见、清掉，不许偷偷占地方。

public extension AppModel {
    /// 图片缓存目录（`YPlayer/Images`，与首页 `Home/`、节目单 `LiveEPG/` 同根）。
    var imageCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    /// 图片缓存占用（字节）：**可清的那部分**（图片数据）——
    /// 不含 `URLCache` 自己的库文件（几十 KB，清了下次访问还会重建，算进来会让「全部缓存」
    /// 与「清空后归零」对不上）。目录不可读算 0。
    var imageCacheByteCount: Int64 {
        clearableImageCacheByteCount
    }

    /// 清空图片缓存，返回删除的文件数。
    ///
    /// **只清「图片数据」**：`URLCache` 自己会在目录里建一份几十 KB 的库文件（它自己的账本，
    /// 不是图片数据；清了它下次访问还会重建）。所以这里删的是「目录里除库文件以外的内容」，
    /// 而不是把目录铲平 —— 条目数按**删除的条目**算，占用按剩余图片数据算。
    ///
    /// **顺序**（上机抓过残留）：① `URLCache` 逻辑清空 + 内存缓存清掉；② 再删目录内容 ——
    /// 倒过来做，①的落盘会把刚删掉的东西又写回去。
    @discardableResult
    func clearImageCache() async -> Int {
        await imageLoader.clear()
        return Self.removeImageContents(of: imageCacheDirectory)
    }

    /// 图片缓存的「可清占用」：目录字节数减去 `URLCache` 自己的库文件（保留项）。
    var clearableImageCacheByteCount: Int64 {
        Self.directoryByteCount(at: imageCacheDirectory) - Self.urlCacheDatabaseByteCount(at: imageCacheDirectory)
    }

    /// `URLCache` 库文件的合计（**不清**的那部分：它自己的索引/库）。
    static func urlCacheDatabaseByteCount(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                continue
            }
            if url.lastPathComponent == "Cache.db" || url.pathExtension == "db" {
                total += Int64(size)
            }
        }
        return total
    }

    /// 删「图片数据」：目录里的内容，**留下** `URLCache` 的库文件。
    static func removeImageContents(of directory: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            if entry.pathExtension == "db" {
                continue
            }
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 目录里所有文件的合计大小（字节）。
    static func directoryByteCount(at directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    /// 删掉目录里的全部内容（保留目录本身），返回删除的文件数。
    static func removeContents(of directory: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var removed = 0
        for entry in entries {
            if (try? FileManager.default.removeItem(at: entry)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
