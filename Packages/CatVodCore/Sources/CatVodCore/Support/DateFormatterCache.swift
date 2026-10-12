import Foundation

/// `DateFormatter` 的**缓存**（M28P19）：formatter 的创建 + 格式编译走 ICU —— 单次开销不小，
/// 而 EPG / 时移这条链是**逐条节目**在解析与格式化（一档节目单上千条：每条 parse ×2 + format ×3），
/// 现建现用就是几千次白编译。这里放的是「格式 + 时区」的成品：取到直接 `date(from:)` /
/// `string(from:)` 用。
///
/// 键 = 「格式 + 时区标识」：这就是协议格式的全部变量（locale 一律锁 `en_US_POSIX`，
/// 不能被用户区域设置改写）。
///
/// 线程安全：锁保护字典；`DateFormatter` 自 iOS 7 起**只读即线程安全** ——
/// **取到之后只许读，别再改它**（改了就影响所有使用者）。
enum DateFormatterCache {
    /// 上限：格式集本来就小（十几种），给足余量；满了整锅清掉。
    static let limit = 64

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: DateFormatter] = [:]

    /// 取（或建）这个「格式 + 时区」的 formatter。
    static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let key = format + "\u{1}" + timeZone.identifier
        lock.lock()
        defer { lock.unlock() }
        if let hit = storage[key] {
            return hit
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        if storage.count >= Self.limit {
            storage.removeAll(keepingCapacity: true)
        }
        storage[key] = formatter
        return formatter
    }
}
