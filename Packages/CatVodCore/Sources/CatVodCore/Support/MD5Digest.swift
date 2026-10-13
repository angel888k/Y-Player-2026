import Foundation

public extension MD5 {
    /// 是否为 32 位十六进制摘要。
    ///
    /// 与参考实现 webhtv `NodeBundle.isMd5` 同款口径：`.md5` 端点的内容**必须**是这个形状才算校验值，
    /// 上游返回 HTML 错误页、空文件或半截内容时一律按「拿不到校验值」处理 ——
    /// 否则会把错误页当成摘要用来比对，判定结果毫无意义。
    static func isDigest(_ value: String) -> Bool {
        guard value.count == 32 else {
            return false
        }
        return value.allSatisfy(\.isHexDigit)
    }

    /// 从文本里抠出**第一段** 32 位十六进制摘要；没有返回 nil（M28P24）。
    ///
    /// 为什么要有它：`.md5` 端点并非都只回「光秃秃 32 字节」——`md5sum` 风格
    /// （`<hash>  index.js`）、带引号的 JSON 都见过；只要文件里有一枚合法摘要就认它，
    /// 否则这些接口会被判成「拿不到校验值」，首次导入直接失败。
    /// 只认**完整的一 run**（40 位 sha1 / 64 位 sha256 不吃，也不会从里面截一段）。
    static func firstDigest(in text: String) -> String? {
        var run = ""
        for character in text.lowercased() {
            if character.isHexDigit {
                run.append(character)
                continue
            }
            if run.count == 32 {
                return run
            }
            run = ""
        }
        return run.count == 32 ? run : nil
    }
}
