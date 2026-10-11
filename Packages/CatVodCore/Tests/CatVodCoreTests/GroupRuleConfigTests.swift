@testable import CatVodCore
import Foundation
import Testing

/// 分组规则的**生效集合**（对齐上游 `GroupRuleConfig`）：内置 + 接口规则，再合并抽标签。
///
/// 本地开关与自建规则那一层已随设置页那份管理界面一起删除（2026-10-11），所以这里只剩两条口径：
/// 「谁生效」与「抽出来的顺序」。
@Suite("分组规则的生效集合（对齐 GroupRuleConfig）")
struct GroupRuleConfigTests {
    @Test("内置 + 接口规则一起抽，结果去重且保持顺序")
    func mergesAndDedupes() {
        let interfaceRule = GroupRule(id: "hash", name: "井号", regex: "#(.+)$", source: GroupRule.sourceInterface)

        let groups = GroupRuleConfig.extract("[主力]站点A#新组", interfaceRules: [interfaceRule])

        #expect(groups == ["主力", "新组"])
    }

    @Test("接口规则自己写了 `enabled=false`、或正则编不出来：都不生效")
    func inactiveInterfaceRulesAreSkipped() {
        let off = GroupRule(
            id: "off",
            name: "关掉",
            regex: "#(.+)$",
            enabled: false,
            source: GroupRule.sourceInterface
        )
        let broken = GroupRule(id: "broken", name: "坏", regex: "(", source: GroupRule.sourceInterface)

        let active = GroupRuleConfig.activeRules(interfaceRules: [off, broken])

        #expect(!active.contains { $0.id == "off" })
        #expect(!active.contains { $0.id == "broken" })
        #expect(active.count == GroupRuleConfig.builtins.count)
    }

    @Test("没有 id 的接口规则直接跳过（对齐上游 `TextUtils.isEmpty(rule.getId())`）")
    func rulesWithoutIDAreSkipped() {
        let anonymous = GroupRule(id: "", name: "没 id", regex: "#(.+)$", source: GroupRule.sourceInterface)

        let active = GroupRuleConfig.activeRules(interfaceRules: [anonymous])

        #expect(active.count == GroupRuleConfig.builtins.count)
    }

    @Test("接口规则排在内置之后 —— 顺序决定同一段名字被多条规则命中时标签的先后")
    func interfaceRulesComeAfterBuiltins() {
        let interfaceRule = GroupRule(id: "i1", name: "接口", regex: "I(.+)$", source: GroupRule.sourceInterface)

        let active = GroupRuleConfig.activeRules(interfaceRules: [interfaceRule])

        #expect(active.map(\.id) == GroupRuleConfig.builtins.map(\.id) + ["i1"])
    }

    @Test("空文本不抽（省得让四条规则空跑）")
    func emptyTextIsIgnored() {
        #expect(GroupRuleConfig.extract("").isEmpty)
    }
}
