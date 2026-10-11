import SwiftUI

/// 播放页的进度条（M28 首验之二十一）：**点 / 拖都能跳**。
///
/// 为什么不用系统 `Slider`：iOS 的 `Slider` **点轨道不跳**（只能拖滑块）—— 用户报
/// 「全屏播放器和精简视图下的竖屏播放器进度条不能点击跳转，只能滑动跳转」。自绘一条：
/// 点在哪儿条就挪到哪儿，**松手（含点完抬手）才真 seek** —— 一次拖动会产生几十个中间值，
/// 逐个 seek 会把内核打爆，这条老口径不变（M03P6）。
///
/// 几何全在 ``SeekBarGeometry``（纯函数，有单测）：滑块**圆心**只在 `[半径, 宽 - 半径]` 里跑，
/// 点两端（含划出轨道）分别落在头 / 尾 —— 与系统滑杆同一条手感。
struct PlaybackSeekBar: View {
    /// 当前显示的位置（秒）。
    let position: Double
    /// 总时长（秒）。
    let duration: Double
    /// 点 / 拖中：把界面上的位置挪到 value（**不** seek）。
    let onScrub: (Double) -> Void
    /// 松手（含点按抬手）：真 seek 到 value。
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midY = proxy.size.height / 2
            let fraction = SeekBarGeometry.progressFraction(position: position, duration: duration)
            let centerX = SeekBarGeometry.thumbCenterX(fraction: fraction, width: width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: width, height: SeekBarGeometry.trackHeight)
                    .position(x: width / 2, y: midY)
                Capsule()
                    .fill(.white)
                    .frame(width: centerX, height: SeekBarGeometry.trackHeight)
                    .position(x: centerX / 2, y: midY)
                Circle()
                    .fill(.white)
                    .frame(width: SeekBarGeometry.thumbDiameter, height: SeekBarGeometry.thumbDiameter)
                    .position(x: centerX, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else {
                            return
                        }
                        onScrub(SeekBarGeometry.time(x: value.location.x, width: width, duration: duration))
                    }
                    .onEnded { value in
                        guard duration > 0 else {
                            return
                        }
                        onCommit(SeekBarGeometry.time(x: value.location.x, width: width, duration: duration))
                    }
            )
        }
        .frame(height: SeekBarGeometry.rowHeight)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(PlaybackView.timeText(position)) / \(PlaybackView.timeText(duration))")
        .accessibilityAdjustableAction { direction in
            guard duration > 0 else {
                return
            }
            switch direction {
            case .increment:
                onCommit(min(position + SeekBarGeometry.accessibilityStep, duration))
            case .decrement:
                onCommit(max(position - SeekBarGeometry.accessibilityStep, 0))
            @unknown default:
                break
            }
        }
    }
}

/// 进度条的几何（纯函数，有单测）—— 系统滑杆那条手感口径：滑块**圆心**只在
/// `[半径, 宽 - 半径]` 里跑，点两端 / 划出轨道分别落在 0 / 1。
enum SeekBarGeometry {
    /// 滑块圆点直径（视觉）；触摸命中区是整条，见 ``rowHeight``。
    static let thumbDiameter: CGFloat = 14
    /// 轨道高度。
    static let trackHeight: CGFloat = 4
    /// 整条（含看不见的触摸区）的高度 —— 4pt 的轨道点不准，得给足手指。
    static let rowHeight: CGFloat = 32
    /// 无障碍「调整」一下走多少秒（固定秒数，比系统滑杆的百分比步好解释）。
    static let accessibilityStep: Double = 10

    /// 播放位置 → 比例（0...1）；总时长还没报出来时算 0。
    static func progressFraction(position: Double, duration: Double) -> Double {
        guard duration > 0 else {
            return 0
        }
        return min(max(position / duration, 0), 1)
    }

    /// 点 / 拖到轨道上的横坐标 → 比例（0...1）。
    static func fraction(x: CGFloat, width: CGFloat) -> Double {
        let span = width - thumbDiameter
        guard span > 0 else {
            return 0
        }
        let raw = (x - thumbDiameter / 2) / span
        return min(max(Double(raw), 0), 1)
    }

    /// 点 / 拖到轨道上的横坐标 → 目标时间（秒）。
    static func time(x: CGFloat, width: CGFloat, duration: Double) -> Double {
        fraction(x: x, width: width) * max(duration, 0)
    }

    /// 比例 → 滑块圆心的 x（轨道填充与圆点都用它）。
    static func thumbCenterX(fraction: Double, width: CGFloat) -> CGFloat {
        let radius = thumbDiameter / 2
        let span = max(width - thumbDiameter, 0)
        return radius + span * CGFloat(min(max(fraction, 0), 1))
    }
}
