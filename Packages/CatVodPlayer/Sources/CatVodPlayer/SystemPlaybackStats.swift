import AVFoundation
import CoreMedia
import Foundation

/// 系统内核（`AVPlayer`）的「播放信息」（M28 收尾）：从 `AVAssetTrack` / 格式描述 / `accessLog`
/// 里读**读得到的那几项**，拼成与另外两个内核同一套原始键（``PlaybackStats/init(rawValues:)``）。
///
/// 为什么现在补：M04 定这条能力时结论是「系统内核给不出这一套」（那时只有 mpv 的属性表可用）——
/// 但 `AVFoundation` 其实报得出画面 / 编码 / 帧率 / 色彩 / 码率 / 音频这几项（公开 API，读的是
/// **媒体自带的元信息**，不是猜的）；缺的只是「读不到的项」—— 原则不变：
/// **读得到就写、读不到那一行就不出现**（不硬造）。
///
/// 系统内核**读不到**的三项（因此它的徽标里没有 `HW/SW`、信息区也没有那三行）：
/// - `hwdec-current`（硬解路径）：`AVPlayer` 不暴露解码器；
/// - 丢帧计数：同上；
/// - `video-out-params/*`（转换后的色彩 / 像素格式）：同上。
///
/// 名字与另外两个内核对齐（`hevc` / `h264` / `pq` / `bt.709`…）：`PlaybackStats` 的文法只认这一套，
/// 系统这边做的是**翻译**（四字码 / 扩展字典 → 同一套名字），不是另造一套词。
/// （mpv 对普通 SDR 片源报的是 `bt.1886`、我们这边两个内核报 `bt.709` —— 同一件事的两种叫法，
/// 各自的属性表怎么写就怎么翻，不强行改一家的词。）
@MainActor
extension AVPlayerEngine: PlaybackStatsProviding {
    /// 读一次播放信息（没在播 / 读不到就给空值，不抛错）。
    public func playbackStats() async -> PlaybackStats {
        guard let item = player.currentItem else {
            return PlaybackStats()
        }
        var raw: [String: String] = [:]
        if let container = Self.containerName(for: item) {
            raw["file-format"] = container
        }
        let asset = item.asset
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            await raw.merge(Self.videoRawValues(track: video, item: item)) { _, new in new }
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            await raw.merge(Self.audioRawValues(track: audio)) { _, new in new }
        }
        return PlaybackStats(rawValues: raw)
    }

    /// 容器名：**只认 URL 后缀**（`mp4` / `mkv` / `m3u8`…）。
    ///
    /// 系统这边没有 demuxer 名可读（mpv 报的是 `mov,mp4,m4a,…` 那种），不编一个像模像样的
    /// 出来 —— 认不出后缀就不写那一行。
    static func containerName(for item: AVPlayerItem) -> String? {
        guard let url = (item.asset as? AVURLAsset)?.url else {
            return nil
        }
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ext.isEmpty, ext.count <= 8 else {
            return nil
        }
        return ext
    }

    /// 视频轨能读到的几项：分辨率 / 帧率 / 码率 / 编码 / 色域 / 传输函数。
    static func videoRawValues(track: AVAssetTrack, item: AVPlayerItem) async -> [String: String] {
        var raw: [String: String] = [:]
        if let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 {
            raw["video-params/w"] = String(Int(size.width.rounded()))
            raw["video-params/h"] = String(Int(size.height.rounded()))
        }
        if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            raw["container-fps"] = String(Double(fps))
        }
        // HLS：`accessLog` 的实时码率更贴实际；点播本地文件没有 accessLog，落到轨道估计值。
        if let observed = observedBitrate(from: item) {
            raw["video-bitrate"] = String(observed)
        } else if let estimated = try? await track.load(.estimatedDataRate), estimated > 0 {
            raw["video-bitrate"] = String(Int(estimated.rounded()))
        }
        if let format = await (try? track.load(.formatDescriptions))?.first {
            raw.merge(videoFormatRawValues(format)) { _, new in new }
        }
        return raw
    }

    /// 格式描述 → 编码名 / 色域 / 传输函数（读得到的才写）。
    static func videoFormatRawValues(_ format: CMFormatDescription) -> [String: String] {
        var raw: [String: String] = [:]
        let fourCC = SystemStatsMapping.fourCCText(CMFormatDescriptionGetMediaSubType(format))
        if let name = SystemStatsMapping.videoCodecName(fourCC: fourCC) {
            raw["video-format"] = name
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        // 色域 / 传输函数的「标签 → 名字」**复用自研内核那份映射**（`LibavVideoDecoder`）：
        // CoreVideo 与 CoreMedia 用的是同一套标签字符串，映射就该只有一份 ——
        // 否则同一个片源，两个内核的「色彩」那行会写出两种词。
        if let value = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let name = LibavVideoDecoder.colorPrimariesName(value)
        {
            raw["video-params/primaries"] = name
        }
        if let value = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           let name = LibavVideoDecoder.transferName(value)
        {
            raw["video-params/gamma"] = name
        }
        return raw
    }

    /// 音频轨能读到的几项：编码 / 采样率 / 声道数。
    static func audioRawValues(track: AVAssetTrack) async -> [String: String] {
        guard let format = await (try? track.load(.formatDescriptions))?.first else {
            return [:]
        }
        var raw: [String: String] = [:]
        let fourCC = SystemStatsMapping.fourCCText(CMFormatDescriptionGetMediaSubType(format))
        if let name = SystemStatsMapping.audioCodecName(fourCC: fourCC) {
            raw["audio-codec"] = name
        }
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if asbd.mSampleRate > 0 {
                raw["audio-params/samplerate"] = String(Int(asbd.mSampleRate.rounded()))
            }
            if asbd.mChannelsPerFrame > 0 {
                raw["audio-params/channel-count"] = String(asbd.mChannelsPerFrame)
            }
        }
        return raw
    }

    /// HLS 的实时码率（`accessLog` 最后一次事件）：观测值优先，其次指示值；都没有给 nil。
    static func observedBitrate(from item: AVPlayerItem) -> Int? {
        guard let event = item.accessLog()?.events.last else {
            return nil
        }
        let value = event.observedBitrate > 0 ? event.observedBitrate : event.indicatedBitrate
        guard value > 0 else {
            return nil
        }
        return Int(value.rounded())
    }
}

/// 系统内核播放信息的**纯映射**（有单测）：四字码 → 与另外两个内核同一套词
/// （`hevc` / `h264` / `aac`…）；色域 / 传输函数那份映射在 `LibavVideoDecoder` 里（复用它，
/// 不两处各写一份）。认不出来的一律给 nil —— 界面按「没读到」处理。
enum SystemStatsMapping {
    /// 四字码（`FourCharCode`）→ 去掉补空格的文本（`avc1` / `hvc1` / `aac ` → `aac`）。
    static func fourCCText(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        guard let text = String(bytes: bytes, encoding: .ascii) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 视频编码四字码 → 编码名（与 mpv 的 `video-format` 同一套词）。
    static func videoCodecName(fourCC: String) -> String? {
        switch fourCC.trimmingCharacters(in: .whitespaces).lowercased() {
        case "avc1", "avc3": "h264"
        case "hvc1", "hev1": "hevc"
        case "av01": "av1"
        case "vp09": "vp9"
        case "mp4v": "mpeg4"
        default: nil
        }
    }

    /// 音频编码四字码 → 编码名（与 mpv 的 `audio-codec` 同一套词）。
    static func audioCodecName(fourCC: String) -> String? {
        switch fourCC.trimmingCharacters(in: .whitespaces).lowercased() {
        case "aac": "aac"
        case "ac-3": "ac3"
        case "ec-3", "eac3": "eac3"
        case "alac": "alac"
        case "lpcm", "sowt", "twos": "pcm"
        case "opus": "opus"
        case "flac": "flac"
        case "mp3", ".mp3": "mp3"
        default: nil
        }
    }
}
