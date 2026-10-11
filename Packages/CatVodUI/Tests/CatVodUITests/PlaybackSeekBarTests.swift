@testable import CatVodUI
import Foundation
import Testing

/// 进度条几何（M28 首验之二十一）：点 / 拖的横坐标 ↔ 比例 ↔ 时间 —— 纯函数，有单测。
@Suite("播放页：进度条几何")
struct PlaybackSeekBarTests {
    @Test("比例：两端与中间；越界夹紧；退化宽度回 0")
    func fraction() {
        // 轨道宽 200、滑块直径 14 → 圆心在 [7, 193] 里跑。
        #expect(SeekBarGeometry.fraction(x: 7, width: 200) == 0)
        #expect(SeekBarGeometry.fraction(x: 193, width: 200) == 1)
        #expect(SeekBarGeometry.fraction(x: 100, width: 200) == 0.5)
        // 点到两端外（含划出轨道）照旧夹在 0 / 1。
        #expect(SeekBarGeometry.fraction(x: -50, width: 200) == 0)
        #expect(SeekBarGeometry.fraction(x: 260, width: 200) == 1)
        // 退化宽度：不崩、回 0。
        #expect(SeekBarGeometry.fraction(x: 5, width: 0) == 0)
        #expect(SeekBarGeometry.fraction(x: 5, width: 10) == 0)
    }

    @Test("时间：比例 × 总时长；夹在两端")
    func time() {
        #expect(SeekBarGeometry.time(x: 7, width: 200, duration: 100) == 0)
        #expect(SeekBarGeometry.time(x: 193, width: 200, duration: 100) == 100)
        #expect(SeekBarGeometry.time(x: 100, width: 200, duration: 100) == 50)
        #expect(SeekBarGeometry.time(x: -10, width: 200, duration: 100) == 0)
    }

    @Test("比例 → 圆心：两端在 [r, 宽 - r]；中间在正中；越界夹紧")
    func thumbCenter() {
        #expect(SeekBarGeometry.thumbCenterX(fraction: 0, width: 200) == 7)
        #expect(SeekBarGeometry.thumbCenterX(fraction: 1, width: 200) == 193)
        #expect(SeekBarGeometry.thumbCenterX(fraction: 0.5, width: 200) == 100)
        #expect(SeekBarGeometry.thumbCenterX(fraction: 2, width: 200) == 193)
        #expect(SeekBarGeometry.thumbCenterX(fraction: -1, width: 200) == 7)
    }

    @Test("播放位置 → 比例：中间、越界、没有总时长")
    func progressFraction() {
        #expect(SeekBarGeometry.progressFraction(position: 30, duration: 120) == 0.25)
        #expect(SeekBarGeometry.progressFraction(position: 200, duration: 120) == 1)
        #expect(SeekBarGeometry.progressFraction(position: -1, duration: 120) == 0)
        #expect(SeekBarGeometry.progressFraction(position: 30, duration: 0) == 0)
    }
}
