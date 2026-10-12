@testable import CatVodNode
import Foundation
import Testing

@Suite("内嵌 Node 启动参数（node_start 的 argv / env）")
struct NodeMobileLaunchPlanTests {
    private func configuration(
        script: String = "/tmp/index.js",
        port: Int = 9988
    ) -> NodeRuntimeConfiguration {
        NodeRuntimeConfiguration(
            scriptURL: URL(fileURLWithPath: script),
            preferredPort: port,
            readinessTimeout: 30
        )
    }

    @Test("argv：固定带 --no-experimental-fetch，末尾仍是脚本（自启动条件成立）")
    func arguments() {
        let plan = NodeMobileLaunchPlan(configuration: configuration())
        // 开关必须钉住：iOS libnode 没有 WebAssembly，不摘掉 undici 那一族全局接口，
        // bundle 一起手就会在 `globalThis.X ||= 自家实现` 的读取上抛错（见 NodePreloadScript）。
        #expect(plan.arguments == ["node", "--no-experimental-fetch", "/tmp/index.js"])
        // node 会先吃掉自己的选项，`process.argv[1]` 仍是脚本路径 —— 自启动只认这个后缀。
        #expect(plan.satisfiesAutoStartContract)
    }

    @Test("脚本名不是 index.js：标记为不满足自启动条件（不应启动）")
    func autoStartContract() {
        let plan = NodeMobileLaunchPlan(configuration: configuration(script: "/tmp/bundle.js"))
        #expect(plan.satisfiesAutoStartContract == false)
    }

    @Test("preload：插在 node 之后、脚本之前（-r）")
    func preload() {
        let plan = NodeMobileLaunchPlan(
            configuration: configuration(),
            preloadURL: URL(fileURLWithPath: "/tmp/preload.js")
        )
        #expect(
            plan.arguments == [
                "node",
                "--no-experimental-fetch",
                "-r",
                "/tmp/preload.js",
                "/tmp/index.js",
            ]
        )
    }

    @Test("环境变量：只注入端口/监听地址/日志开关，且不设 CATVOD_DISABLE_AUTOSTART")
    func environment() {
        let plan = NodeMobileLaunchPlan(configuration: configuration(port: 12345))
        #expect(plan.environment["DEV_HTTP_PORT"] == "12345")
        #expect(plan.environment["HOST"] == "127.0.0.1")
        #expect(plan.environment["NODE_ENV"] == "development")
        #expect(plan.environment["CATVOD_DISABLE_AUTOSTART"] == nil)
        // 其余环境变量继承进程，因此这里恰好三个键。
        #expect(plan.environment.count == 3)
    }

    @Test("withCArguments：argc 与最后一项 argv 正确（指针层面）")
    func cArguments() {
        let plan = NodeMobileLaunchPlan(configuration: configuration())
        let result: (Int32, String?) = plan.withCArguments { argc, argv in
            (argc, argv[Int(argc) - 1].map { String(cString: $0) })
        }
        // argc 跟参数表走（不写死 2：argv 里加开关不该再来改这里），最后一项必须是脚本路径。
        #expect(result.0 == Int32(plan.arguments.count))
        #expect(result.1 == "/tmp/index.js")
    }
}
