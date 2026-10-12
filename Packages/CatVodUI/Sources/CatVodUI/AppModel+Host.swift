import CatVodCore
import CatVodNet
import CatVodSource
import Foundation

// JS2P 宿主（内嵌 Node）的启停、日志与诊断 —— 从 `AppModel` 类体搬出来的第一簇（M06f 遗留第 3 条）。
//
// 为什么先搬它：依赖只有 `js2pHost` / `sessionTransport` / `detailCache` 三个存储属性，内聚度最高、
// 搬动风险最小（存储属性必须留在类体里，这几簇能进扩展的都进扩展，`type_body_length` 才有余量）。

public extension AppModel {
    /// 按加载结果维护宿主：JS 源启动/刷新，其它源停止。
    internal func refreshHost(for source: LoadedSource, forceRestart: Bool) async {
        guard source.kind == .javaScript, let scriptURL = source.cachedURL else {
            await stopHost()
            return
        }
        guard JS2PHostService.isRuntimeAvailable else {
            hostSites = []
            js2pHost = nil
            hostStatus = .unavailable(reason: JS2PHostService.runtimeUnavailableReason)
            return
        }

        // 换了 JS 源：宿主跑的还是上一个 bundle（内嵌 node 每进程只起得了一个实例），
        // 停掉再换一个 —— 否则站点清单永远来自上一个接口。
        if let existing = js2pHost, existing.runtimeConfiguration.scriptURL != scriptURL {
            await existing.stop()
            js2pHost = nil
        }

        hostStatus = .starting
        let service = js2pHost ?? JS2PHostService(
            transport: sessionTransport,
            scriptURL: scriptURL,
            persistsHostOutput: isEngineLogEnabled
        )
        js2pHost = service
        // 开关可能在宿主启动之后被改过（设置 → 数据 → 日志管理）：每次刷新都对一次。
        await service.setLogPersistence(isEngineLogEnabled)
        do {
            // bundle 刚被换过（本次加载真的重下了，`usedCache == false`）就必须重启宿主：
            // 运行中的 node 已经把旧代码执行过，站点清单在内存里 —— 只换磁盘上的文件它不会自己重读。
            // 这是「明明下载了新版本、界面还是旧的」那一类现象的根因（见 M16P9）。
            let bundleReplaced = !source.usedCache
            let snapshot = try await service.sites(forceRestartHost: forceRestart || bundleReplaced)
            hostSites = snapshot.sites
            StartupTrace.note("宿主就绪", detail: "站点 \(snapshot.sites.count)")
            // 刚拿到清单 = 宿主现在活着（省掉一次探活）。
            hostHealth = .online
            let baseURL = await service.currentBaseURL()
            // 落一份快照（M28P14）：下次冷启动先把站点摆出来，不用等宿主（见 ``HostSiteSnapshotStore``）。
            hostSiteSnapshots.save(
                HostSiteSnapshotStore.Snapshot(
                    baseURL: baseURL?.absoluteString ?? "",
                    sites: snapshot.sites,
                    disabledSiteCount: snapshot.disabledSiteCount
                ),
                forScriptURL: scriptURL
            )
            hostStatus = .running(
                baseURL: baseURL?.absoluteString ?? "",
                siteCount: snapshot.sites.count,
                disabledSiteCount: snapshot.disabledSiteCount
            )
            // 站点集合变了：旧详情可能属于别的站点，不能复用。
            await detailCache.invalidateAll()
            await searchCache.removeAll()
            // 宿主活着、清单也就位了：把 js2p 的 init 挪到这段空闲里预热（M28P18）。
            startSitePrewarm()
        } catch {
            hostSites = []
            hostStatus = .failed(reason: userFacingMessage(error))
        }
    }

    /// 重启宿主（接口页按钮）。
    func restartHost() async {
        guard let source = state.loadedSource, source.kind == .javaScript else {
            return
        }
        await refreshHost(for: source, forceRestart: true)
        // 宿主重启会换掉站点清单（端口、站点集合都可能变）：首页/搜索据此作废旧内容。
        bumpSiteCatalogRevision()
    }

    /// 刷一次「站点 `POST /init` 失败清单」（M16P10）：接口页进页面时调，展示在「Node 宿主」区块里。
    ///
    /// 为什么放在宿主那一段：init 是宿主契约的一步，失败原因跟宿主状态放一起看最省事
    /// （M16P6 当时留的口子就是这个）。
    func refreshSiteInitFailures() async {
        siteInitFailures = await spiderInitializer.failureNotes()
    }

    /// 站点清单就绪后**预热** js2p 的 `POST /init`（M28P18）。
    ///
    /// 为什么要预热：init 是「建 spider 实例」的准备步骤 —— 本地宿主几毫秒就回；但死站点的
    /// init 会悬到超时，第一次聚合搜索就得为它白等一截（上机实测：`末站回报 − 全部开搜 ≈ 16 秒`
    /// = 8 秒 init + 8 秒 search）。把它挪到「清单刚就绪、人还在发现页」这段空闲里跑掉，
    /// 搜索时绝大多数站点已经 init 过（``CatSpiderInitializer`` 对已完成的站点是瞬回）。
    ///
    /// 口径：只挑**能跑的 js2p 站点**；并发 6（不给宿主与连接池添堵）；失败照旧只记账
    /// （init 的语义：只发一次、失败不阻断），所以这里**不 await**。
    internal func startSitePrewarm() {
        let client = makeSiteClient()
        let targets = hostSites.compactMap { site -> CatSpiderHTTPClient? in
            guard site.availability.isAvailable else {
                return nil
            }
            guard case let .catSpider(spider)? = try? client.resolve(site) else {
                return nil
            }
            return spider
        }
        guard !targets.isEmpty else {
            return
        }
        let initializer = spiderInitializer
        Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                let limit = 6
                while next < targets.count, next < limit {
                    let target = targets[next]
                    next += 1
                    group.addTask { await initializer.ensureInitialized(target) }
                }
                for await _ in group {
                    guard next < targets.count else {
                        continue
                    }
                    let target = targets[next]
                    next += 1
                    group.addTask { await initializer.ensureInitialized(target) }
                }
            }
        }
    }

    /// 冷启动：把上次落盘的站点清单先摆出来（M28P14，见 ``HostSiteSnapshotStore``）。
    ///
    /// 只对 JS 源有意义（别的源的站点就在配置里）。摆出来之后**立刻通知界面**（自增 revision）——
    /// 发现页据此用「首页缓存」渲染那个站点的内容；宿主起来后 ``refreshHost(for:forceRestart:)``
    /// 再整体替换一次（端口也跟着对齐）。
    internal func publishCachedHostSites(for source: LoadedSource) {
        guard source.kind == .javaScript, let scriptURL = source.cachedURL else {
            return
        }
        guard let snapshot = hostSiteSnapshots.load(forScriptURL: scriptURL), !snapshot.sites.isEmpty else {
            return
        }
        hostSites = snapshot.sites
        StartupTrace.note("站点快照已就位", detail: "站点 \(snapshot.sites.count)（宿主还在起）")
        bumpSiteCatalogRevision()
    }

    /// 停止宿主并清空宿主站点。
    func stopHost() async {
        await js2pHost?.stop()
        js2pHost = nil
        hostSites = []
        hostStatus = .idle
        hostHealth = .unknown
        bumpSiteCatalogRevision()
    }

    /// 探一次宿主**现在**是否还活着（M22P1）：`GET /health`，几毫秒的事。
    ///
    /// 没有宿主时给 `.unknown`（不是 `offline` —— 那不叫离线，那叫「当前接口不需要宿主」）。
    func refreshHostHealth() async {
        guard let host = js2pHost else {
            hostHealth = .unknown
            return
        }
        hostHealth = await host.health() ? .online : .offline
    }

    /// 宿主落盘日志路径（没有落盘能力时为 nil）。
    ///
    /// 日志开关（``AppModel/isEngineLogEnabled``）决定宿主是否把输出写文件；
    /// 「设置 → 数据 → 日志管理 → 导出」用它拿到要导出的内容。
    func hostLogPath() async -> URL? {
        await js2pHost?.hostLogPath()
    }

    /// 宿主最近输出：内存里的尾部 + 落盘日志的尾部（见 ``JS2PHostService``）。
    ///
    /// 「源地址 → Node 宿主 → 查看宿主输出」与「设置 → 数据 → 日志管理」共用它；
    /// 没有宿主（未加载 JS 源 / 平台不支持）时返回空数组，界面据此显示「暂无输出」。
    func hostDiagnostics(limit: Int = 20) async -> [String] {
        guard let host = js2pHost else {
            return []
        }
        return await host.hostDiagnostics(limit: limit)
    }

    /// 把日志开关应用到正在运行的宿主。
    ///
    /// 宿主不能重建（内嵌 node 每进程只能起一个实例），所以开关必须能**运行中改**；
    /// 宿主还没起来时什么都不做 —— 下次 ``refreshHost(for:forceRestart:)`` 会带上当前值。
    internal func applyLogPreferenceToHost() {
        guard let host = js2pHost else {
            return
        }
        Task {
            await host.setLogPersistence(isEngineLogEnabled)
        }
    }
}

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
///
/// 为什么住在 UI 包（而不是 `CatVodSource`）：它只服务 `AppModel` 的冷启动提速 ——
/// 跟着用它的代码走，跨包就少一个类型（少了「依赖包新增文件、消费方构建没刷新」这类事故）。
struct HostSiteSnapshotStore: Sendable {
    /// 落盘的形状（`Site` 本身是 `Codable` —— 配置里的站点就是这么解的）。
    struct Snapshot: Codable, Sendable, Equatable {
        /// 上次的宿主地址前缀（诊断用；`sites` 里的 `api` 已经是绝对地址）。
        var baseURL: String
        var sites: [Site]
        var disabledSiteCount: Int
    }

    private let snapshotDirectory: URL

    init(directory: URL) {
        snapshotDirectory = directory
    }

    /// 存一份（原子写；写不上不算错 —— 下次再存，快照只是加速件）。
    func save(_ snapshot: Snapshot, forScriptURL scriptURL: URL) {
        guard !snapshot.sites.isEmpty, let url = snapshotFileURL(forScriptURL: scriptURL) else {
            return
        }
        do {
            if !FileManager.default.fileExists(atPath: snapshotDirectory.path) {
                try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            }
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        } catch {
            // 只读 / 满盘等场景：静默跳过（快照坏了也不该影响加载流程）。
        }
    }

    /// 读回（没有 / 坏了给 nil）。
    func load(forScriptURL scriptURL: URL) -> Snapshot? {
        guard let url = snapshotFileURL(forScriptURL: scriptURL), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// 文件名：`host-sites-<md5(scriptURL)>.json`（与别的缓存同一种命名习惯；一个脚本一份）。
    private func snapshotFileURL(forScriptURL scriptURL: URL) -> URL? {
        let digest = MD5.hexDigest(of: Data(scriptURL.absoluteString.utf8))
        return snapshotDirectory.appendingPathComponent("host-sites-\(digest).json")
    }
}
