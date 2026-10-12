@testable import CatVodNode
import Foundation
import Testing

/// 账本存在的唯一理由：第二次 `node_start` 会把**整个 App** abort 掉
/// （`InitializeNodeWithArgs` 的 `CHECK`，见 ``NodeMobileStartLedger``）——
/// 所以「谁还能启动」必须被钉死，不能靠真机去撞。
@Suite("内嵌 node 启动账本（每进程只能启动一次）")
struct NodeMobileStartLedgerTests {
    private let firstPath = "/tmp/bundle-a/index.js"
    private let secondPath = "/tmp/bundle-b/index.js"

    @Test("第一次给 launch，并把账记下（端口还没有）")
    func firstClaimLaunches() {
        let ledger = NodeMobileStartLedger()
        #expect(ledger.claim(scriptPath: firstPath) == .launch)
        #expect(ledger.current()?.scriptPath == firstPath)
        #expect(ledger.current()?.readyPort == nil)
    }

    @Test("同一个脚本：复用；就绪之后连端口一起带回来")
    func sameScriptReuses() {
        let ledger = NodeMobileStartLedger()
        #expect(ledger.claim(scriptPath: firstPath) == .launch)
        #expect(ledger.claim(scriptPath: firstPath) == .reuse(port: nil))
        ledger.noteReady(port: 9988)
        #expect(ledger.claim(scriptPath: firstPath) == .reuse(port: 9988))
    }

    @Test("换成别的脚本：挡住（不能拿 App 去撞第二次 node_start）")
    func differentScriptBlocks() {
        let ledger = NodeMobileStartLedger()
        #expect(ledger.claim(scriptPath: firstPath) == .launch)
        #expect(ledger.claim(scriptPath: secondPath) == .blocked(existingScriptPath: firstPath))
        // 再问一次还是同样的结论：账不会因为被拒绝而改变。
        #expect(ledger.current()?.scriptPath == firstPath)
    }

    @Test("启动前失败可以还账；已经就绪的账不能还")
    func abandonOnlyBeforeReady() {
        let ledger = NodeMobileStartLedger()
        #expect(ledger.claim(scriptPath: firstPath) == .launch)
        ledger.abandon(scriptPath: firstPath)
        #expect(ledger.current() == nil)
        #expect(ledger.claim(scriptPath: secondPath) == .launch)

        ledger.noteReady(port: 9989)
        ledger.abandon(scriptPath: secondPath)
        #expect(ledger.current()?.scriptPath == secondPath, "就绪之后不能再把账还回去")
    }

    @Test("并发抢许可：只能有一个 launch")
    func concurrentClaimsYieldOneLaunch() async {
        let ledger = NodeMobileStartLedger()
        let path = firstPath
        let launched = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    ledger.claim(scriptPath: path) == .launch
                }
            }
            var count = 0
            for await didLaunch in group where didLaunch {
                count += 1
            }
            return count
        }
        #expect(launched == 1)
    }
}
