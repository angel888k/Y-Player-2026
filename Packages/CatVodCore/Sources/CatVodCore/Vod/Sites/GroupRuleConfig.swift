import Foundation

/// 分组规则的「生效集合」：内置规则 + 接口规则，以及最终的抽标签入口。
///
/// 对应上游 `setting/GroupRuleConfig.java`（那边叫 Config，实际是「这一堆规则的生效集合」）。
/// 上游还有两个来源**本项目不做**：`GroupRuleStore.loadUser()`（用户自建）与 `AiGroupRuleStore`（AI 生成）——
/// 管理它们的那份设置页（内置开关 + 接口规则开关 + 自建规则）**已于 2026-10-11 拍板删除**，
/// 所以 `userRules` / `disabledIDs` 那一层随之删除，生效集合就是「内置 + 接口里 `enabled` 的那些」。
public enum GroupRuleConfig {
    /// 内置规则 id：方括号标签。
    public static let builtinBracket = "builtin_bracket_tag"
    /// 内置规则 id：竖线后缀。
    public static let builtinPipe = "builtin_pipe_quality"
    /// 内置规则 id：框线分隔。
    public static let builtinBox = "builtin_box_separator"
    /// 内置规则 id：圆点后缀。
    public static let builtinBullet = "builtin_bullet_suffix"

    /// 四条内置规则（正则与顺序都照上游 `builtins()` 抄，改动请先跑 `GroupRuleTests`）。
    public static var builtins: [GroupRule] {
        [
            .builtin(id: builtinBracket, name: "方括号标签", regex: "\\[([^\\]]+)\\]"),
            .builtin(id: builtinPipe, name: "竖线后缀", regex: "(?i)(?:[|｜])\\s*([^|｜]+?)\\s*$"),
            .builtin(id: builtinBox, name: "框线分隔", regex: "(?i)┆\\s*([^┆]+)\\s*$"),
            .builtin(id: builtinBullet, name: "圆点后缀", regex: "(?i)(?:[•·])\\s*([^•·]+?)\\s*$"),
        ]
    }

    /// 当前生效的规则：四条内置（恒生效）+ 接口规则里自己写了 `enabled` 且正则编得出来的。
    ///
    /// 顺序决定同一段站点名被多条规则命中时标签的先后，所以别随手调：内置在前、接口在后。
    /// 没有 id 的接口规则直接跳过（对齐上游 `TextUtils.isEmpty(rule.getId())`）。
    static func activeRules(interfaceRules: [GroupRule] = []) -> [GroupRule] {
        var rules = builtins.filter(\.isValid)
        for rule in interfaceRules where !rule.id.isEmpty && rule.enabled && rule.isValid {
            rules.append(rule)
        }
        return rules
    }

    /// 从文本里抽标签（对齐上游 `GroupRuleConfig.extract`）：所有生效规则的结果合并、**去重**、保持出现顺序。
    public static func extract(_ text: String, interfaceRules: [GroupRule] = []) -> [String] {
        guard !text.isEmpty else { return [] }
        var groups: [String] = []
        for rule in activeRules(interfaceRules: interfaceRules) {
            for group in rule.extract(text) where !groups.contains(group) {
                groups.append(group)
            }
        }
        return groups
    }
}
