import AVFoundation
@testable import CatVodPlayer
import CoreMedia
import Foundation
import Testing

/// 系统内核的「播放信息」（M28 收尾）：四字码 → 与另外两个内核同一套词。
///
/// CI 能测的部分就这些（纯映射）；真读媒体那一份在下面两个套件里。
@Suite("系统内核：播放信息（四字码映射）")
struct SystemStatsMappingTests {
    @Test("四字码 → 文本：去掉补空格、转小写（AAC 的四字码是 \"aac \"）")
    func fourCCText() {
        #expect(SystemStatsMapping.fourCCText(0x6161_6320) == "aac")
        #expect(SystemStatsMapping.fourCCText(0x6876_6331) == "hvc1")
        // 补位是 NUL 也一样（`aac` + NUL 的写法）
        #expect(SystemStatsMapping.fourCCText(0x6161_6300) == "aac")
        // 全 0 的四字码（没有媒体时）给空串，不给一串看不见的 NUL。
        #expect(SystemStatsMapping.fourCCText(0).isEmpty)
    }

    @Test("视频编码四字码 → 编码名（认不出的给 nil，不猜）")
    func videoCodecNames() {
        #expect(SystemStatsMapping.videoCodecName(fourCC: "avc1") == "h264")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "avc3") == "h264")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "hvc1") == "hevc")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "hev1") == "hevc")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "av01") == "av1")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "vp09") == "vp9")
        #expect(SystemStatsMapping.videoCodecName(fourCC: "xxxx") == nil)
    }

    @Test("音频编码四字码 → 编码名")
    func audioCodecNames() {
        // AAC 的两个四字码都认：MP4 里是 `mp4a`、TS / ADTS 是 `aac `（去空格后 `aac`）。
        #expect(SystemStatsMapping.audioCodecName(fourCC: "mp4a") == "aac")
        #expect(SystemStatsMapping.audioCodecName(fourCC: "aac") == "aac")
        #expect(SystemStatsMapping.audioCodecName(fourCC: "ac-3") == "ac3")
        #expect(SystemStatsMapping.audioCodecName(fourCC: "ec-3") == "eac3")
        #expect(SystemStatsMapping.audioCodecName(fourCC: "lpcm") == "pcm")
        #expect(SystemStatsMapping.audioCodecName(fourCC: "xxxx") == nil)
    }
}

/// 格式描述 → 原始键：真造一个 `CMVideoFormatDescription`（带色域 / 传输函数扩展），
/// 不碰媒体文件 —— 这一条钉的是「扩展字典读得对、颜色走的是自研内核那份映射」。
///
/// `@MainActor`：`videoFormatRawValues` 是 `AVPlayerEngine`（@MainActor）的静态成员 ——
/// 与 `SystemPlayerTracksTests` 同一理由（首验就栽在这里：非隔离上下文调主 actor 静态方法）。
@MainActor
@Suite("系统内核：格式描述 → 播放信息原始键")
struct SystemStatsFormatDescriptionTests {
    private func makeFormat(
        codec: CMVideoCodecType,
        primaries: String?,
        transfer: String?
    ) -> CMFormatDescription? {
        var extensions: [String: Any] = [:]
        if let primaries {
            extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
        }
        if let transfer {
            extensions[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
        }
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: 3840,
            height: 2160,
            extensions: extensions.isEmpty ? nil : (extensions as CFDictionary),
            formatDescriptionOut: &format
        )
        #expect(status == noErr)
        return format
    }

    @Test("HEVC + BT.2020 + PQ：编码 / 色域 / 传输函数都写进原始键，PlaybackStats 认得出 HDR")
    func hdrHevc() throws {
        let format = try #require(makeFormat(
            codec: kCMVideoCodecType_HEVC,
            primaries: "ITU_R_2020",
            transfer: "SMPTE_ST_2084_PQ"
        ))
        let raw = AVPlayerEngine.videoFormatRawValues(format)
        #expect(raw["video-format"] == "hevc")
        #expect(raw["video-params/primaries"] == "bt.2020")
        #expect(raw["video-params/gamma"] == "pq")
        let stats = PlaybackStats(rawValues: raw.merging([
            "video-params/w": "3840",
            "video-params/h": "2160",
        ]) { _, new in new })
        #expect(stats.isHDR)
        #expect(stats.dynamicRangeText == "HDR · PQ (ST2084) · BT.2020")
        #expect(stats.resolutionText == "3840×2160")
        // 系统内核读不到的项不许编：丢帧 / 硬解 / 输出那三行就是空的（界面上不出现）。
        #expect(stats.decodeText.isEmpty)
        #expect(stats.dropText.isEmpty)
        #expect(stats.outputText.isEmpty)
    }

    @Test("H.264 + 709：SDR（传输函数走自研内核那份映射：709 → bt.709）")
    func sdrH264() throws {
        let format = try #require(makeFormat(
            codec: kCMVideoCodecType_H264,
            primaries: "ITU_R_709_2",
            transfer: "ITU_R_709_2"
        ))
        let raw = AVPlayerEngine.videoFormatRawValues(format)
        #expect(raw["video-format"] == "h264")
        #expect(raw["video-params/primaries"] == "bt.709")
        #expect(raw["video-params/gamma"] == "bt.709")
        #expect(!PlaybackStats(rawValues: raw).isHDR)
    }
}

/// 端到端：真写一个 320×240 的小 MP4（`TinyMP4Fixture`），让系统内核读一遍。
@MainActor
@Suite("系统内核：播放信息（真读一个小 MP4）", .enabled(if: VideoStackAvailability.isUsable, "CI 跳过：GitHub 运行器没有硬件视频栈"))
struct SystemPlaybackStatsEndToEndTests {
    @Test("画面 / 编码 / 帧率 / 容器 / 音频都对得上；读不到的项不写假值")
    func readsTinyMP4() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yp-system-stats-\(UUID().uuidString).mp4")
        try await TinyMP4Fixture.write(to: url, width: 320, height: 240, fps: 30, frames: 30, audioSeconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVPlayerEngine(decoderMode: .hardware)
        try await engine.load(MediaResource(url: url.absoluteString))
        let stats = await engine.playbackStats()
        await engine.teardown()

        #expect(stats.videoWidth == 320)
        #expect(stats.videoHeight == 240)
        #expect(stats.videoFormat == "h264")
        #expect(stats.fps > 29 && stats.fps < 31)
        // 容器只认后缀（系统没有 demuxer 名可读）——「mp4」就是文件后缀。
        #expect(stats.fileFormat == "mp4")
        #expect(stats.audioCodec == "aac")
        #expect(stats.audioSampleRate == 44100)
        #expect(stats.audioChannels == 2)
        // 读不到的项不写假值（那几行在界面上不出现）。
        #expect(stats.decodeText.isEmpty)
        #expect(stats.dropText.isEmpty)
        #expect(stats.outputText.isEmpty)
    }
}
