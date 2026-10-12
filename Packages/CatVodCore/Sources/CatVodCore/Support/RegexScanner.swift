import Foundation

/// 正则小工具：仓库里多处需要「Java 风格的正则查找/替换」，语义必须一致。
///
/// 为什么单独成类型：`Sniffer`（嗅探规则）、`Catchup`（时移模板）、`HostRuleMatcher`（host 规则）
/// 都要用同一套语义 —— **查找是 `find()`（能找到就行），不是整串匹配**；正则非法时统一退化为「不命中」，
/// 而不是抛异常或崩溃（上游 Java 会抛 `PatternSyntaxException` 被上层吞掉，行为等价但更难排查）。
public enum RegexScanner {
    /// 编译（带缓存）——仓库里「自己拿 `NSRegularExpression` 用」的地方都该走它（M28P19）。
    ///
    /// 为什么要有缓存：`NSRegularExpression(pattern:)` 的编译走 ICU、单次不便宜，而这条链上的
    /// 模式都是**小集合反复用**：分组规则（每个站点名 × 每条规则）、嗅探规则（每个解析任务逐条试）、
    /// 时移模板（每个节目一条，而且那个模式是常量）、播放列表逐行解析、host 规则整串匹配 ——
    /// 现编现用就是成百上千次白编译。非法模式返回 `nil`（与各调用处的「退化为不命中」语义一致）。
    ///
    /// `NSRegularExpression` 只读可多线程共享；缓存本身锁保护。**取到之后只许拿它查找/替换**。
    public static func compiled(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else {
            return nil
        }
        return regexCache.regex(pattern)
    }

    /// 编译缓存（见 ``compiled(_:)``）。
    private static let regexCache = RegexCache()

    /// 正则**找得到**（Java `Matcher.find()`）。
    public static func finds(_ pattern: String, in text: String) -> Bool {
        firstMatch(pattern, in: text) != nil
    }

    /// 正则查找并返回第一处匹配（Java `m.group(0)`）；正则非法或文本为空时返回 `nil`。
    public static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard !text.isEmpty, let regex = compiled(pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), let matched = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matched])
    }

    /// 正则替换（Java `String.replaceAll` 也是**正则**替换）；正则非法时退化为原样返回。
    ///
    /// 注意 `template` 里的 `$1` 会被当作捕获组引用（与 Java/`NSRegularExpression` 一致）。
    public static func replacingMatches(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = compiled(pattern) else {
            return text
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    /// 捕获组列表（Java `m.group(i)`）；`0` 是整段匹配。不匹配时返回空数组。
    public static func groups(_ pattern: String, in text: String) -> [String] {
        guard !text.isEmpty, let regex = compiled(pattern) else {
            return []
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return []
        }
        return (0 ..< match.numberOfRanges).map { index in
            guard let groupRange = Range(match.range(at: index), in: text) else {
                return ""
            }
            return String(text[groupRange])
        }
    }
}

/// `NSRegularExpression` 的定容缓存（线程安全）：满了**整锅清掉**
/// —— 模式集本来就是小集合（配置里的那几十条），重建比维护 LRU 划算。
private final class RegexCache: @unchecked Sendable {
    static let limit = 256

    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[pattern] {
            return hit
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        if storage.count >= Self.limit {
            storage.removeAll(keepingCapacity: true)
        }
        storage[pattern] = compiled
        return compiled
    }
}
