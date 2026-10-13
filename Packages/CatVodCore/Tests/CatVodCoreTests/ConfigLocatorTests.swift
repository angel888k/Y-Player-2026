import CatVodCore
import Foundation
import Testing

@Suite("MD5（index.js.md5 校验）")
struct MD5Tests {
    @Test("RFC 1321 测试向量")
    func knownVectors() {
        #expect(MD5.hexDigest(of: "") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hexDigest(of: "abc") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(MD5.hexDigest(of: "The quick brown fox jumps over the lazy dog") == "9e107d9d372bb6826bd81d3542a419d6")
        // 跨块（> 64 字节）输入
        let long = String(repeating: "a", count: 1000)
        #expect(MD5.hexDigest(of: long).count == 32)
        #expect(MD5.hexDigest(of: Data(long.utf8)) == MD5.hexDigest(of: long))
    }

    @Test("摘要比对大小写不敏感并忽略空白")
    func matches() {
        #expect(MD5.matches("35DCC10D533153DBB94298792664AD04", "35dcc10d533153dbb94298792664ad04"))
        #expect(MD5.matches(" 35dcc10d533153dbb94298792664ad04\n", "35dcc10d533153dbb94298792664ad04"))
        #expect(!MD5.matches("abc", "abd"))
    }
}

@Suite("配置入口定位（.js ↔ .js.md5）")
struct ConfigLocatorTests {
    @Test("JS 源配置：关联 .js.md5 校验地址与 index.js 缓存路径")
    func javascriptConfig() throws {
        let source = try #require(ConfigLocator.locate("https://9280.kstore.vip/ceshi/index.js"))
        #expect(source.kind == .javaScript)
        // 关键：校验地址是 index.js.md5，而不是 index.md5
        #expect(source.digestURL?.absoluteString == "https://9280.kstore.vip/ceshi/index.js.md5")
        // 缓存路径必须**以 index.js 结尾**（bundle 的自启动条件），且每接口一个目录
        #expect(source.cacheFileName.hasPrefix("bundle-"))
        #expect(source.cacheFileName.hasSuffix("/index.js"))
    }

    @Test("JSON 配置：无校验地址，缓存名为 .json")
    func jsonConfig() throws {
        let source = try #require(ConfigLocator.locate("https://example.com/tvbox/config.json"))
        #expect(source.kind == .json)
        #expect(source.digestURL == nil)
        #expect(source.cacheFileName.hasSuffix(".json"))
    }

    @Test("内联 JSON：按内容摘要生成缓存名")
    func inlineConfig() throws {
        let source = try #require(ConfigLocator.locate(#"{"sites":[]}"#))
        #expect(source.kind == .inline)
        #expect(source.url == nil)
        #expect(source.cacheFileName.hasPrefix("inline-"))
    }

    @Test("相对路径以配置文件为基准解析")
    func relativeResolution() throws {
        let base = try #require(URL(string: "https://example.com/tvbox/index.json"))
        let source = try #require(ConfigLocator.locate("./sub/config.json", relativeTo: base))
        #expect(source.url?.absoluteString == "https://example.com/tvbox/sub/config.json")
    }

    @Test("空输入与无法解析的相对路径返回 nil")
    func invalidInputs() {
        #expect(ConfigLocator.locate("   ") == nil)
        #expect(ConfigLocator.locate("./config.json") == nil)
    }

    @Test("是否需要重新下载的判定")
    func downloadDecision() {
        let digest = "35dcc10d533153dbb94298792664ad04"
        // 远端无摘要 → 必须下载
        #expect(ConfigLocator.needsDownload(remoteDigest: "", localDigest: digest))
        // 本地没有缓存 → 必须下载
        #expect(ConfigLocator.needsDownload(remoteDigest: digest, localDigest: nil))
        // 摘要一致 → 命中缓存
        #expect(!ConfigLocator.needsDownload(remoteDigest: digest, localDigest: digest))
        // 摘要不同 → 重新下载
        #expect(ConfigLocator.needsDownload(remoteDigest: digest, localDigest: MD5.hexDigest(of: "other")))
    }

    @Test("填 .js.md5 是正规输入（参考实现 webhtv 就是让用户这么填）：归一化为 .js 且与 .js 填法同缓存")
    func digestFileIsCanonicalInput() throws {
        let fromDigest = try #require(ConfigLocator.locate("https://9280.kstore.vip/ceshi/index.js.md5"))
        let fromScript = try #require(ConfigLocator.locate("https://9280.kstore.vip/ceshi/index.js"))

        #expect(fromDigest.kind == .javaScript)
        #expect(fromDigest.url?.absoluteString == "https://9280.kstore.vip/ceshi/index.js")
        #expect(fromDigest.digestURL?.absoluteString == "https://9280.kstore.vip/ceshi/index.js.md5")
        // 两种填法必须落到同一个缓存目录，否则同一个源会被重复下载 6 MB
        #expect(fromDigest.cacheFileName == fromScript.cacheFileName)
        #expect(fromDigest.cacheFileName.hasSuffix("/index.js"))
    }

    @Test("普通 .md5（不是 JS 源的校验文件）仍按 JSON 处理")
    func plainDigestStaysJSON() throws {
        let source = try #require(ConfigLocator.locate("https://example.com/tvbox/config.md5"))
        #expect(source.kind == .json)
    }

    @Test("从文本里抠第一段摘要：md5sum 写法 / 带引号都认，40 位 sha1 不吃（M28P24）")
    func firstDigestFromText() {
        let digest = "35dcc10d533153dbb94298792664ad04"
        #expect(MD5.firstDigest(in: "\(digest)  index.js") == digest)
        #expect(MD5.firstDigest(in: "{\"md5\":\"\(digest)\"}") == digest)
        #expect(MD5.firstDigest(in: digest.uppercased()) == digest)
        #expect(MD5.firstDigest(in: "没有摘要") == nil)
        #expect(MD5.firstDigest(in: "da39a3ee5e6b4b0d3255bfef95601890afd80709 \(digest)") == digest)
    }

    @Test("`.js.md5` 带查询串（token / 版本号）：仍走 JS 源，查询串原样保留（M28P24）")
    func digestFileWithQueryStaysJavaScript() throws {
        let source = try #require(ConfigLocator.locate("https://host/cat/index.js.md5?v=3"))
        #expect(source.kind == .javaScript)
        #expect(source.url?.absoluteString == "https://host/cat/index.js?v=3")
        #expect(source.digestURL?.absoluteString == "https://host/cat/index.js.md5?v=3")
    }

    @Test("后缀大小写不敏感；`.js?t=` 的校验地址拼在路径之后（M28P24）")
    func digestSuffixCaseAndQuery() throws {
        let upper = try #require(ConfigLocator.locate("https://host/cat/index.JS.MD5"))
        #expect(upper.kind == .javaScript)
        #expect(upper.url?.absoluteString == "https://host/cat/index.JS")
        #expect(upper.digestURL?.absoluteString == "https://host/cat/index.JS.md5")

        let query = try #require(ConfigLocator.locate("https://host/cat/main.js?t=2026"))
        #expect(query.kind == .javaScript)
        #expect(query.digestURL?.absoluteString == "https://host/cat/main.js.md5?t=2026")
    }
}

@Suite("媒体直链嗅探")
struct MediaFormatSnifferTests {
    @Test("常见媒体扩展名")
    func extensions() {
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.MP4"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.mkv"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.flv"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8?token=abc&e=1"))
        #expect(MediaFormatSniffer.isVideoFormat("https://a/b.m3u8#frag"))
    }

    @Test("非媒体地址")
    func nonMedia() {
        #expect(!MediaFormatSniffer.isVideoFormat("video-1001"))
        #expect(!MediaFormatSniffer.isVideoFormat("https://a/b.html"))
        #expect(!MediaFormatSniffer.isVideoFormat(""))
        #expect(!MediaFormatSniffer.isVideoFormat("https://a/page?id=x.m3u8"))
    }

    @Test("MIME 线索与本地文件")
    func mimeAndLocal() {
        #expect(MediaFormatSniffer.isVideoFormat("https://a/play?format=application/vnd.apple.mpegurl"))
        #expect(MediaFormatSniffer.isLocalFileURL("file:///tmp/a.mp4"))
        #expect(!MediaFormatSniffer.isLocalFileURL("https://a/b.mp4"))
    }
}
