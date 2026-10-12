@testable import CatVodCore
import Foundation
import Testing

/// 编译缓存的账（M28P19）：正则与日期格式化的「现编现用」在这条链上是成百上千次的白开销。
@Suite("正则 / 日期格式化：编译缓存")
struct RegexAndFormatterCacheTests {
    @Test("同一个正则：第二次取到的是同一份编译结果（对象身份可比）")
    func regexCacheReusesCompiledPattern() throws {
        let first = try #require(RegexScanner.compiled("a+b"))
        let second = try #require(RegexScanner.compiled("a+b"))
        #expect(first === second)
    }

    @Test("空模式与非法的正则都返回 nil（调用方照旧「退化为不命中」）")
    func regexCacheDegrades() {
        #expect(RegexScanner.compiled("") == nil)
        #expect(RegexScanner.compiled("([") == nil)
    }

    @Test("同一「格式 + 时区」取到同一份 formatter；换格式 / 换时区就各是一份")
    func dateFormatterCacheReuses() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let utc = try #require(TimeZone(identifier: "UTC"))
        let first = DateFormatterCache.formatter(format: "HH:mm", timeZone: shanghai)
        let second = DateFormatterCache.formatter(format: "HH:mm", timeZone: shanghai)
        let otherFormat = DateFormatterCache.formatter(format: "yyyy-MM-dd", timeZone: shanghai)
        let otherZone = DateFormatterCache.formatter(format: "HH:mm", timeZone: utc)
        #expect(first === second)
        #expect(first !== otherFormat)
        #expect(first !== otherZone)
        // 经缓存产出的 formatter 口径不变：协议格式 + 指定时区。
        #expect(first.locale.identifier == "en_US_POSIX")
        #expect(first.timeZone.identifier == "Asia/Shanghai")
    }
}
