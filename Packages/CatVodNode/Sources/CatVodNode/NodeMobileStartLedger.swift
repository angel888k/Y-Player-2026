import Foundation

/// 内嵌 node 的**进程级启动账本**（iOS：nodejs-mobile）。
///
/// 存在的理由是一条硬事实 —— fork v18.20.4 的 `src/node.cc`：
/// `node_start` 就是 `node::Start`，而它必经的 `InitializeNodeWithArgs` 第一行是
/// `CHECK(!init_called.exchange(true))`。**第二次调用不是报错，是 abort 整个进程**
/// （宿主 App 一起死，没有返回值可判断）。所以「本进程还能不能再启动 node」必须在调
/// `node_start` **之前**由账本回答，不能指望 bundle 或框架给一个干净的失败。
///
/// 账本同时回答「复用」：同一个脚本已经在跑时（`stopHost()` 之后重新加载同一个 JS 接口），
/// 新的宿主服务应当拿回同一地址，而不是再启动一次（也启动不了）。
///
/// 平台无关：不依赖 NodeMobile —— 单测在任何平台都能跑，只有 iOS 的运行时用得到它
/// （见 ``NodeMobileRuntime``）。
public final class NodeMobileStartLedger: @unchecked Sendable {
    /// 请求启动许可的结果。
    public enum Claim: Equatable {
        /// 本进程还没有启动过 node：可以正常走 `node_start`；账本已记下这次启动。
        case launch
        /// **同一个脚本**已经在启动或就绪：复用它的实例；`port` 为空 = 就绪行还没出现。
        case reuse(port: Int?)
        /// **别的脚本**已经启动过：没重启 App 就换不了（`node_start` 不能再调）。
        case blocked(existingScriptPath: String)
    }

    /// 进程共享实例（宿主只用这个）。
    public static let shared = NodeMobileStartLedger()

    private let lock = NSLock()
    private var scriptPath: String?
    private var readyPort: Int?

    /// 独立实例：单测各用各的，互不串账。
    public init() { }

    /// 请求启动许可。`.launch` 会**记下**这条账（此后本进程不能再启动别的脚本）。
    public func claim(scriptPath: String) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = self.scriptPath else {
            self.scriptPath = scriptPath
            return .launch
        }
        guard existing == scriptPath else {
            return .blocked(existingScriptPath: existing)
        }
        return .reuse(port: readyPort)
    }

    /// 就绪行给出的**实际**端口（由真正启动了 node 的那个运行时上报）。
    public func noteReady(port: Int) {
        lock.lock()
        readyPort = port
        lock.unlock()
    }

    /// 启动前就失败了（管道建不出来等）：把账还回去 —— 此时 `node_start` 并没有被调用。
    ///
    /// 只还「没就绪」的账：已经拿到就绪行的实例不可能停（见 ``NodeMobileRuntime/stop()``）。
    public func abandon(scriptPath: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.scriptPath == scriptPath, readyPort == nil else {
            return
        }
        self.scriptPath = nil
    }

    /// 当前账（诊断 / 断言用）：脚本路径与已知端口。
    public func current() -> (scriptPath: String, readyPort: Int?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let scriptPath else {
            return nil
        }
        return (scriptPath, readyPort)
    }
}
