import Foundation

/// 内嵌 Node 的**预载脚本**（通过 ``NodeMobileLaunchPlan/preloadURL`` 注入 `-r`）。
///
/// 存在的理由来自一次真实失败：iOS 模拟器上跑真 bundle 时，测试进程在下载完成后
/// **13.5 秒凭空消失**（XCTest 只报 `Restarting after unexpected exit, crash, or test timeout`），
/// 没有任何断言输出 —— 因为 nodejs-mobile 是**进程内嵌**：
///
/// - bundle 里的致命错误（例如用到 iOS 版不提供的 `child_process`/`worker_threads`）
///   会让 node 调 `process.exit()`，而它退出就等于**宿主 App 退出**；
/// - 我们 `dup2` 抓到的 stdout 缓冲**随进程一起消失**，事后无从取证。
///
/// 因此预载做三件事：
///
/// 1. 把运行环境（版本、`argv`、`cwd`、关键 env、核心模块可用性）与致命错误
///    **逐行追加到 `YPLAYER_NODE_LOG`** —— 进程死了文件还在，这是唯一能带回来的证据；
/// 2. 拦截 `process.exit` / `uncaughtException` / `unhandledRejection`：记录堆栈并**保活**。
///    这样「宿主起不来」会变成界面上的「宿主未就绪 + 日志尾部」，而不是闪退；
/// 3. **摘掉 undici 背着的全局接口**（只在没有 `WebAssembly` 的 iOS libnode 上）：
///    node 18 里 `fetch`/`Headers`/`Request`/`Response`/`FormData` 都由 undici 背书
///    （`fetch` 是包装函数，其余四个是**惰性 getter**）—— **读一下**就会加载 undici 的
///    模块图，而它在没有 WebAssembly 的 iOS 上加载即抛
///    `ReferenceError: WebAssembly is not defined`（2026-10-12 实测：kstore 的 6.5 MB
///    bundle 启动时中招，宿主拿不到就绪行，落盘日志里是完整 undici 栈）。
///    bundle 自带的兜底（`globalThis.X ||= 自家实现`）恰恰死在「先读一下」上；
///    把这一族摘掉，它就会装上自己的 node-fetch v3。
///    启动参数那边还有一层 `--no-experimental-fetch`（见 ``NodeMobileLaunchPlan``）。
///
/// 平台无关（只依赖 Foundation）：macOS 上也能单测脚本内容与写盘行为。
public enum NodePreloadScript {
    /// 落盘日志的路径通过这个环境变量告诉预载脚本。
    public static let logEnvironmentKey = "YPLAYER_NODE_LOG"
    /// 预载脚本文件名。
    public static let fileName = "yplayer-node-preload.js"
    /// 落盘日志文件名。
    public static let logFileName = "yplayer-node.log"

    /// 预载脚本源码。
    ///
    /// 刻意保持极简：只读环境、只写日志、只拦致命退出，**不碰** bundle 依赖的任何内部实现
    /// （预载一旦出错同样会带走宿主，所以它必须小到可以人工审阅）。
    public static let source = """
    /* YPlayer 内嵌 Node 预载脚本（由 NodeMobileLaunchPlan 以 -r 注入）。
     * 目的：把「内嵌 node 出错 → 宿主 App 直接死掉」变成「可回读的日志」。
     * 只做诊断，不改变 bundle 行为。 */
    (function () {
      'use strict';
      var fs = require('fs');
      var logPath = process.env.YPLAYER_NODE_LOG || '';

      function write(line) {
        var text = '[' + new Date().toISOString() + '] ' + line + '\\n';
        try { if (logPath) { fs.appendFileSync(logPath, text); } } catch (e) {}
        try { process.stderr.write('[YPlayer] ' + line + '\\n'); } catch (e) {}
      }

      function detail(error) {
        if (!error) { return String(error); }
        return error.stack ? String(error.stack) : String(error);
      }

      write('preload node=' + process.version + ' argv=' + JSON.stringify(process.argv));
      write('preload cwd=' + process.cwd());
      write('preload entry=' + (process.argv[1] || '<none>'));
      write('preload DEV_HTTP_PORT=' + process.env.DEV_HTTP_PORT
        + ' HOST=' + process.env.HOST);

      /* nodejs-mobile 18（fork 的 lib/internal/process/pre_execution.js「setupFetch」）里：
       * `fetch` 是包着 undici 的函数，`FormData`/`Headers`/`Request`/`Response` 是**惰性 getter** ——
       * 读一下就 require('internal/deps/undici/undici')，而 iOS 版 libnode 没有 WebAssembly，
       * undici 的模块图在加载时就会抛 `ReferenceError: WebAssembly is not defined`
       * （llhttp wasm；2026-10-12 实测：kstore 的 6.5 MB bundle 启动时中招，宿主卡死）。
       * bundle 本来有兜底（`globalThis.X ||= 自家实现`），却被这个「先读一下」毁掉 ——
       * 所以这里在 bundle 之前把这一族全局接口摘掉，只查属性描述符、**不读取访问器**
       * （读取本身就会触发加载）。`Blob` 来自 buffer、不背 undici，不动它。
       * 启动参数那边还有一层 `--no-experimental-fetch`（见 NodeMobileLaunchPlan），
       * 两层都生效时这一族本来就不存在，这里会记下「一个都没有」。 */
      if (typeof WebAssembly === 'undefined') {
        var undiciBackedGlobals = ['fetch', 'Headers', 'Request', 'Response', 'FormData'];
        var removedGlobals = [];
        undiciBackedGlobals.forEach(function (name) {
          if (!Object.getOwnPropertyDescriptor(globalThis, name)) {
            return;
          }
          var removed = false;
          try { removed = delete globalThis[name]; } catch (deleteError) {}
          if (!removed) {
            try {
              Object.defineProperty(globalThis, name, { value: undefined, writable: true, configurable: true });
              removed = true;
            } catch (defineError) {}
          }
          if (removed) {
            removedGlobals.push(name);
          }
        });
        write('preload 摘掉 undici 背着的全局接口（无 WebAssembly 的 iOS libnode）: '
          + (removedGlobals.length > 0 ? removedGlobals.join(', ') : '(一个都没有)'));
      }

      /* iOS 版 libnode 不提供全部核心模块（无 child_process / worker_threads）。
       * 逐个试加载并记录：这样「bundle 一起手就没有就绪行」时有第一手证据 —— 正是
       * docs/任务记录/M16P4-iOS内嵌libnode.md 里列的第 4 个未验证项。 */
      var names = ['child_process', 'worker_threads', 'cluster', 'vm', 'net', 'http', 'fs'];
      names.forEach(function (name) {
        try { require(name); write('preload module ok: ' + name); }
        catch (moduleError) {
          write('preload module MISSING: ' + name + ' -> ' + moduleError.message);
        }
      });

      process.on('uncaughtException', function (error) {
        write('FATAL uncaughtException: ' + detail(error));
      });
      process.on('unhandledRejection', function (reason) {
        write('FATAL unhandledRejection: ' + detail(reason));
      });

      process.exit = function (code) {
        write('BLOCKED process.exit(' + code + ') ' + detail(new Error('process.exit')));
        throw new Error('YPlayer blocked process.exit(' + code + ')');
      };

      write('preload ready (process.exit blocked)');
    })();
    """

    /// 预载脚本与落盘日志的暂存目录。
    ///
    /// 用临时目录而不是 App Bundle：真机上的 Bundle 不可写，而 node 需要能**读到**脚本本身
    /// （顺带验证「bundle 之外的路径 node 能不能读」，见实机验证清单第 5 项）。
    public static func stagingDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("yplayer-node", isDirectory: true)
    }

    /// 落盘日志路径（与 ``stagingDirectory(fileManager:)`` 同目录）。
    public static func logURL(fileManager: FileManager = .default) -> URL {
        stagingDirectory(fileManager: fileManager).appendingPathComponent(logFileName)
    }

    /// 把 ``source`` 写到暂存目录并返回路径。
    ///
    /// 幂等：内容一致就不重写（避免每次启动都动文件时间戳）。
    @discardableResult
    public static func materialize(fileManager: FileManager = .default) throws -> URL {
        let directory = stagingDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let data = Data(source.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return url
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 读取落盘日志的尾部若干行（进程已消失时唯一可用的诊断来源）。
    public static func tail(lines: Int = 20, fileManager: FileManager = .default) -> [String] {
        guard lines > 0, let text = try? String(contentsOf: logURL(fileManager: fileManager), encoding: .utf8),
              !text.isEmpty
        else {
            return []
        }
        let all = text.split(whereSeparator: \.isNewline).map(String.init)
        return Array(all.suffix(lines))
    }
}
