import CatVodCore
import Foundation

/// 宿主站点清单的**落盘快照**（M28P14）：冷启动先把上次的清单摆出来，宿主就绪后再整体替换。
///
/// 为什么需要它（用户口径「已经导入过接口的情况下，冷启动的站点加载是优先缓存吗」）：
/// **原来不是** —— JS 源的站点清单只在宿主里（`GET /full-config`），而宿主启动要几秒：
/// 没有站点就没有发现页，连「上次看过的首页缓存」都摆不出来，用户盯着的是一个转圈。
/// 存一份快照之后：
/// - 冷启动立刻摆出站点（发现页随即用**首页缓存**渲染那个站点的内容，一字节网络都不用）；
/// - 宿主就绪后 ``JS2PHostService/sites(forceRestartHost:)`` 拿到的清单会整体替换它
///   （连同把站点的 `api` 换成本次的宿主地址）。
///
/// 已知取舍：快照里 JS 站点的 `api` 带着**上次的宿主端口**（首选 9988，被占才顺延）——
/// 端口多数时候不变；变了的话「宿主起来之前的那几秒里点进去会失败」，起来之后就没这回事。
/// 这一点比「整页转圈」划算，写在这里免得后来者当成 bug 修。
public struct HostSiteSnapshotStore: Sendable {
    /// 落盘的形状（`Site` 本身是 `Codable` —— 配置里的站点就是这么解的）。
    public struct Snapshot: Codable, Sendable, Equatable {
        /// 上次的宿主地址前缀（诊断用；`sites` 里的 `api` 已经是绝对地址）。
        public var baseURL: String
        public var sites: [Site]
        public var disabledSiteCount: Int

        public init(baseURL: String, sites: [Site], disabledSiteCount: Int) {
            self.baseURL = baseURL
            self.sites = sites
            self.disabledSiteCount = disabledSiteCount
        }
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 存一份（原子写；写不上不算错 —— 下次再存，快照只是加速件）。
    public func save(_ snapshot: Snapshot, forScriptURL scriptURL: URL) {
        guard !snapshot.sites.isEmpty, let url = fileURL(forScriptURL: scriptURL) else {
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // 只读 / 满盘等场景：静默跳过（快照坏了也不该影响加载流程）。
        }
    }

    /// 读回（没有 / 坏了给 nil）。
    public func load(forScriptURL scriptURL: URL) -> Snapshot? {
        guard let url = fileURL(forScriptURL: scriptURL), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 文件名：`host-sites-<md5(scriptURL)>.json`（与别的缓存同一种命名习惯；一个脚本一份）。
    private func fileURL(forScriptURL scriptURL: URL) -> URL? {
        let digest = MD5.hexDigest(of: Data(scriptURL.absoluteString.utf8))
        return directory.appendingPathComponent("host-sites-\(digest).json")
    }
}
