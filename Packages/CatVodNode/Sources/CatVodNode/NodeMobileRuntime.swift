#if canImport(NodeMobile)
import Foundation
import NodeMobile

/// iOS 内嵌 Node 运行时（nodejs-mobile 的 `NodeMobile.xcframework`）。
///
/// 与 macOS 的进程方式**共用同一个契约**（``NodeRuntimeLaunching``）和同一套就绪解析（``NodeReadiness``）：
///
/// | 环节 | 做法 | 依据 |
/// | --- | --- | --- |
/// | 启动 | 独立后台线程（2 MB 栈）里调 `node_start(argc, argv)` | 参考实现 `NodeJSRunner.mm` |
/// | 参数 | `argv = ["node", "<script>"]`；`DEV_HTTP_PORT`/`HOST`/`NODE_ENV` 走 `setenv` | ``NodeMobileLaunchPlan`` |
/// | 就绪 | 把 fd 1/2 重定向到管道，按行解析 `CatVodSpiderios listening on …` | `docs/js2p宿主契约.md` |
///
/// 硬约束（nodejs-mobile 的既定事实，不是我们的选择）：
/// - **每进程只能起一个 Node 实例**，`node_start` 不可重入 —— 第二次调用会在
///   `InitializeNodeWithArgs` 的 `CHECK(!init_called…)` 上 **abort 整个进程**
///   （fork v18.20.4 的 `src/node.cc`），所以「还能不能启动」由 ``NodeMobileStartLedger``
///   在调用之前回答，见 `start()`；
/// - 没有 `child_process`；iOS 无 JIT；必须跑在独立线程上。
///
/// 因此 ``stop()`` 只能**断开日志采集**：Node 实例与它监听的本地服务仍在运行，
/// 再次 ``start()`` 会返回同一个 baseURL / 接着等就绪（见 `resumeStartedNode()`），
/// 同一个脚本被新的宿主服务接管时走账本。要真正重启 / 换脚本只能重启 App ——
/// 这条限制写进返回值与文档，而不是假装「停掉了」。
public actor NodeMobileRuntime: NodeRuntimeLaunching {
    /// 「运行时可改」而不是 `let`：日志开关（``NodeRuntimeConfiguration/persistsHostOutput``）
    /// 需要在宿主已启动的情况下生效 —— 内嵌 node 每进程只能起一个实例，重建运行时不可行。
    private var configuration: NodeRuntimeConfiguration

    // 与 NodeRuntimeAdapter 同构的状态机（模块内可见，便于同文件内的扩展读写）。
    var isRunning = false
    var isReady = false
    var readyPort: Int?
    var lastExitCode: Int32?
    var output: [String] = []
    var waiters: [CheckedContinuation<URL, Error>] = []
    var timeoutTask: Task<Void, Never>?

    /// Node 是否已经在跑（`node_start` 不可逆，因此这个标记一旦为真就不再回退）。
    private(set) var nodeStarted = false
    private var pipeReadFD: Int32 = -1
    private var savedStdoutFD: Int32 = -1
    private var savedStderrFD: Int32 = -1
    /// 落盘日志路径（仅当预载成功注入时非空；诊断时附给调用方）。
    private var preloadLogURL: URL?
    /// 落盘日志文件句柄（日志开关打开时按需打开；写失败会置空、下次重试）。
    private var logHandle: FileHandle?

    public init(configuration: NodeRuntimeConfiguration) {
        self.configuration = configuration
    }

    // MARK: - 启动与停止

    public func start() async throws -> URL {
        // 已经起过：Node 不会重复打印就绪行，直接返回已知地址（见类型注释里的 stop 语义）。
        if nodeStarted, let port = readyPort, let url = NodeReadiness.baseURL(port: port) {
            isReady = true
            return url
        }
        guard configuration.satisfiesAutoStartContract else {
            throw NodeRuntimeError.invalidConfiguration(
                reason: "脚本文件名必须是 index.js（当前 \(configuration.scriptURL.lastPathComponent)），否则 bundle 不会自启动"
            )
        }
        // 本实例已经启动过、但还没拿到就绪行：不能再来一次 `node_start`，只能接着等
        // （就绪行可能只是比上一次的等待窗口来得晚 —— 直接拒绝会把「再等等就好」变成
        // 「重启 App 才能再试」，那正是用户首验截图上的那条消息）。
        if nodeStarted {
            return try await resumeStartedNode()
        }

        // 进程级账本：内嵌 node 每进程只能启动一次，第二次 `node_start` 会 abort 整个 App ——
        // 必须先问账本（见 ``NodeMobileStartLedger``），而不是指望它报错。
        let scriptPath = configuration.scriptURL.path
        switch NodeMobileStartLedger.shared.claim(scriptPath: scriptPath) {
        case .launch:
            break
        case let .reuse(port):
            if let port, let url = NodeReadiness.baseURL(port: port) {
                // 同一个脚本的实例还在跑：接管地址即可（本运行时看不到它的 stdout，
                // 诊断以落盘日志为准 —— 那份日志本来就是为「跨运行时回读」设计的）。
                nodeStarted = true
                isReady = true
                readyPort = port
                return url
            }
            throw NodeRuntimeError.launchFailed(
                reason: "同一个脚本的宿主已经在启动、还没拿到就绪行：内嵌 Node 每进程只能启动一次，"
                    + "先等它；一直不就绪就重启 App 再试"
            )
        case let .blocked(existingPath):
            throw NodeRuntimeError.launchFailed(
                reason: "内嵌 Node 每进程只能启动一次：当前进程跑的是另一个脚本（\(existingPath)），"
                    + "不能再启动 \(scriptPath)。想换 JS 接口（或换过版本后重新加载）需要重启 App。"
            )
        }

        do {
            try startStdoutCapture()
        } catch {
            // 还没走到 `node_start`：把账还回去 —— 别把一次纯管道故障记成「本进程起过 node」。
            NodeMobileStartLedger.shared.abandon(scriptPath: scriptPath)
            throw error
        }

        let (plan, logURL) = makeLaunchPlan()
        preloadLogURL = logURL
        for (key, value) in plan.environment {
            setenv(key, value, 1)
        }
        nodeStarted = true
        isRunning = true
        startNodeThread(plan: plan)

        return try await waitForReadiness()
    }

    /// 本实例**已经**启动过 node、但还没拿到就绪行时的续等（`start()` 的第二入口）。
    ///
    /// 为什么不是直接报错：`node_start` 不可能重来，而就绪行可能只是比上一次的等待窗口
    /// 来得晚（bundle 首次拉远端配置 / 冷网）。续等让每次「重试」都有意义；真的没来，
    /// 报的仍是带输出的超时 —— 不是一句无从下手的「无法再次启动」。
    func resumeStartedNode() async throws -> URL {
        if let code = lastExitCode {
            throw exitedBeforeReadyError(code: code)
        }
        // `stop()` 断开过采集：续等之前接回来（幂等），否则就绪行永远到不了这里。
        try startStdoutCapture()
        return try await waitForReadiness()
    }

    /// 「就绪前退出」错误 + iOS 特有的出路（内嵌 node 不能重启，只能重启 App）。
    ///
    /// 提示挂在输出末尾：``NodeRuntimeError/exitedBeforeReady(code:output:)`` 的文案会把整段
    /// 输出展示出来，而这条错误在 iOS 上几乎只有一种出路，不写出来用户只剩一个 exit code。
    func exitedBeforeReadyError(code: Int32) -> NodeRuntimeError {
        var output = recentOutput(limit: 20).joined(separator: "\n")
        if !output.isEmpty {
            output += "\n"
        }
        output += "[YPlayer] 内嵌 node 每进程只能启动一次；重启 App 后可以再试"
        return .exitedBeforeReady(code: code, output: output)
    }

    /// 断开日志采集（**不是**停掉 Node —— 见类型注释）。
    public func stop() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        restoreStdoutCapture()
        isRunning = false
        isReady = false
        // 注意：readyPort 保留 —— Node 还在跑，重新 start() 要能拿回同一个地址。
        failWaiters(with: .stopped)
    }

    // MARK: - 输出与状态

    public func recentOutput(limit: Int = 40) -> [String] {
        Array(output.suffix(max(limit, 0)))
    }

    /// 落盘日志路径（进程消失后仍可读）—— 见 ``NodePreloadScript``。
    public func persistentLogPath() async -> URL? {
        preloadLogURL
    }
}

extension NodeMobileRuntime {
    /// 组装启动参数：注入 ``NodePreloadScript`` 并把落盘日志路径告诉它。
    ///
    /// 预载是**诊断增强**，不是启动前提：写不出脚本也要照常启动，
    /// 否则一个日志功能会把整条链路拖死。
    func makeLaunchPlan() -> (NodeMobileLaunchPlan, URL?) {
        var configuration = configuration
        // NODE_PATH 指向 bundle 同级的 data/（见 NodeRuntimeConfiguration.bundleDataDirectory）。
        if let dataDirectory = configuration.makeBundleDataDirectory() {
            configuration.environment["NODE_PATH"] = dataDirectory.path
        } else {
            output.append("无法创建 bundle 的 data/ 目录，未设置 NODE_PATH（bundle 的 db/代理缓存可能不可用）")
        }
        guard configuration.prefersPreload else {
            return (NodeMobileLaunchPlan(configuration: configuration), nil)
        }
        do {
            let preloadURL = try NodePreloadScript.materialize()
            let logURL = NodePreloadScript.logURL()
            configuration.environment[NodePreloadScript.logEnvironmentKey] = logURL.path
            return (NodeMobileLaunchPlan(configuration: configuration, preloadURL: preloadURL), logURL)
        } catch {
            output.append("预载脚本写入失败（继续启动，本次没有落盘日志）：\(error)")
            return (NodeMobileLaunchPlan(configuration: configuration), nil)
        }
    }
}

extension NodeMobileRuntime {
    // MARK: - stdout / stderr 采集

    /// 把 fd 1/2 重定向到管道。
    ///
    /// 为什么不靠 nodejs-mobile 的 bridge：bridge 是 cordova 插件用 JS 预载实现的，
    /// 我们只需要 bundle 打印的那一行就绪日志 —— 直接抓 fd 更少依赖、也更接近 macOS 的进程方式。
    func startStdoutCapture() throws {
        // 幂等：`stop()` 之后续等就绪时要再挂一次；已经挂着就什么都不做 ——
        // 二次 `dup2` 会把管道 fd 当成「保存的 stdout」记下来，`restoreStdoutCapture()` 还错。
        guard pipeReadFD < 0 else {
            return
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw NodeRuntimeError.launchFailed(reason: "无法创建 stdout 管道（errno \(errno)）")
        }
        savedStdoutFD = dup(STDOUT_FILENO)
        savedStderrFD = dup(STDERR_FILENO)
        dup2(fds[1], STDOUT_FILENO)
        dup2(fds[1], STDERR_FILENO)
        close(fds[1])
        pipeReadFD = fds[0]
        startReaderThread(fd: fds[0])
    }

    func restoreStdoutCapture() {
        if savedStdoutFD >= 0 {
            dup2(savedStdoutFD, STDOUT_FILENO)
            close(savedStdoutFD)
            savedStdoutFD = -1
        }
        if savedStderrFD >= 0 {
            dup2(savedStderrFD, STDERR_FILENO)
            close(savedStderrFD)
            savedStderrFD = -1
        }
        if pipeReadFD >= 0 {
            // 关掉读端让阻塞中的 read 返回，读线程自然退出。
            close(pipeReadFD)
            pipeReadFD = -1
        }
    }

    private func startReaderThread(fd: Int32) {
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                guard let text = String(bytes: buffer[0 ..< count], encoding: .utf8) else {
                    continue
                }
                Task { await self?.consume(text) }
            }
        }
        thread.name = "YPlayer.NodeMobile.reader"
        thread.start()
    }

    // MARK: - Node 线程

    private func startNodeThread(plan: NodeMobileLaunchPlan) {
        let thread = Thread { [weak self] in
            let code = plan.withCArguments { argc, argv in
                node_start(argc, argv)
            }
            Task { await self?.handleNodeExit(code: code) }
        }
        // 与参考实现一致：给 Node 线程 2 MB 栈（V8 在移动端更吃栈）。
        thread.stackSize = 2 * 1024 * 1024
        thread.name = "YPlayer.NodeMobile"
        thread.start()
    }

    // MARK: - 就绪状态机（与 NodeRuntimeAdapter 同一套规则）

    func consume(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            output.append(trimmed)
            if output.count > 200 {
                output.removeFirst(output.count - 200)
            }
            persistIfNeeded(trimmed)
            if let port = NodeReadiness.port(fromLine: trimmed) {
                markReady(port: port)
            }
        }
    }

    /// 运行时切换落盘（设置 → 数据 → 日志管理 → 日志开关）。
    ///
    /// 只改标记，不碰已经采集到的输出：开关打开后**从下一行起**开始落盘，
    /// 关掉后也不再追加（已经在文件里的历史保留，用户可在日志页导出或清理）。
    public func setPersistsHostOutput(_ enabled: Bool) async {
        configuration.persistsHostOutput = enabled
    }

    /// 把一行输出追加到落盘日志（仅在开关打开时）。
    ///
    /// 写不上（磁盘满、容器权限异常）就放弃本次落盘并把句柄置空：内存输出仍在，
    /// 诊断能力不因此丢失 —— 落盘是增强，不是前提。
    private func persistIfNeeded(_ line: String) {
        guard configuration.persistsHostOutput else {
            return
        }
        do {
            let url = NodePreloadScript.logURL()
            if logHandle == nil {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                logHandle = handle
            }
            try logHandle?.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            logHandle = nil
        }
    }

    func markReady(port: Int) {
        guard !isReady else {
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let url = NodeReadiness.baseURL(port: port) else {
            failWaiters(with: .invalidConfiguration(reason: "就绪行端口无法构造 URL：\(port)"))
            return
        }
        isReady = true
        readyPort = port
        // 账本记下实际端口：同一个脚本被新的宿主服务接管时（换回同一个接口），要把地址带回去。
        NodeMobileStartLedger.shared.noteReady(port: port)
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: url)
        }
    }

    func handleNodeExit(code: Int32) {
        lastExitCode = code
        isRunning = false
        guard !isReady else {
            // 就绪之后退出：保留 readyPort 供诊断（与 adapter 的行为一致）。
            return
        }
        failWaiters(with: exitedBeforeReadyError(code: code))
    }

    func waitForReadiness() async throws -> URL {
        if !isReady, let code = lastExitCode {
            throw exitedBeforeReadyError(code: code)
        }
        let timeout = configuration.readinessTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            waiters.append(continuation)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                if Task.isCancelled {
                    return
                }
                await self?.failWaitersOnTimeout(seconds: timeout)
            }
        }
    }

    func failWaitersOnTimeout(seconds: TimeInterval) {
        failWaiters(
            with: .readinessTimeout(seconds: seconds, output: recentOutput(limit: 20).joined(separator: "\n"))
        )
    }

    func failWaiters(with error: NodeRuntimeError) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }
}
#endif
