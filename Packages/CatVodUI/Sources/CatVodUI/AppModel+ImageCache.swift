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

    /// 图片缓存占用（字节）：磁盘目录的合计（与 `homeCacheByteCount` 同一口径，目录不可读算 0）。
    var imageCacheByteCount: Int64 {
        Self.directoryByteCount(at: imageCacheDirectory)
    }

    /// 清空图片缓存，返回删除的文件数。
    ///
    /// **顺序要紧**（上机抓过：先删文件、后清 `URLCache`，清完目录里会冒出 144KB 残留）：
    /// ① 先让 `URLCache` 逻辑上清空 —— 它自己还开着分片目录里的库文件，清的时候会落盘；
    /// ② 再把内存缓存清掉（不清的话进程内那层会把已删的图继续吐出来）；
    /// ③ **最后**删目录里的文件 —— 倒过来做，①的落盘会把刚删掉的东西又写回去。
    @discardableResult
    func clearImageCache() async -> Int {
        await imageLoader.clear()
        return Self.removeContents(of: imageCacheDirectory)
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
