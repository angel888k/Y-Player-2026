import SwiftUI

/// 播放页的「走到头之后干什么」（M28 从 `PlaybackView.swift` 拆出）。
///
/// 两块：**锁屏之后还留哪些手势**（``PlaybackView/LockedGesturePolicy``，M03P21）与
/// **一集播完 / 到片尾标记之后的动作**（``PlaybackView/EndAction``，M03P20/M12P1）——
/// 两条都是纯规则（有单测），加上它们的两个动作（单集循环、从头播放）。
///
/// 为什么拆出去：`PlaybackView.swift` 的行数又贴到 SwiftLint 的 `file_length` error（800）——
/// 与 `+Stats` / `+Engine` / `+Overlays` / `+NowPlaying` 同一套做法；跨文件用到的成员本来就是模块内。
extension PlaybackView {
    /// 锁上之后还允许哪些手势（**纯函数**，有单测）。
    enum LockedGesturePolicy: Equatable {
        /// 没锁：全开。
        case all
        /// 锁上：**只留单击**（把控制条叫出来 / 收起来）—— 双击、拖动、长按加速、捏合全停。
        ///
        /// 为什么留着单击：锁上时控制条只剩解锁按钮，而它跟别的控制条一样会「播放中自动收起」——
        /// 单击是把它叫回来的唯一办法（上游也是这么留的：`onSingleTap` 不看 lock）。
        case singleTapOnly
    }

    static func lockedGesturePolicy(isLocked: Bool) -> LockedGesturePolicy {
        isLocked ? .singleTapOnly : .all
    }

    /// 一集走到头（或到片尾标记）之后该干什么（**纯函数**，有单测）。
    ///
    /// 循环**优先于**连播：开了循环就是「这一集重来」，片尾标记不再把人带走
    /// （上游把循环做在内核层 —— 播完根本不到 `ended`；我们做在播放页这一层，三个内核都吃得到）。
    enum EndAction: Equatable {
        case loop
        case nextEpisode
        case stop
    }

    static func endAction(isRepeatOne: Bool, hasNextEpisode: Bool) -> EndAction {
        if isRepeatOne {
            return .loop
        }
        return hasNextEpisode ? .nextEpisode : .stop
    }

    /// 单集循环：回到本集开头接着播（不改进度记录里的「看完」，也不动选集下标）。
    func loopCurrentEpisode() async {
        // 这一集重新开始：进度条回到 0，结束态、片尾跳集的「跳过」标记、续播文案都清掉。
        latestPosition = 0
        isFinished = false
        didSkipEnding = false
        resumedFromText = ""
        guard let engine else {
            return
        }
        await engine.seek(to: 0)
        await engine.play()
    }

    /// 从头播放：清掉进度记录、回到 0 秒**接着播**。
    ///
    /// 为什么要显式 `play()`（M28P9）：这条路多是一集播完之后点的（列表里那颗「从头播放」），
    /// 而三个内核在 `ended` 之后 `seek` 回去都**不会自己再播** —— AVPlayer 的 rate 还是 0、
    /// mpv 停在 EOF、自研内核停在结束态。只 seek 不 play，点下去画面就停在 0 秒不动
    /// （同一个文件里的 ``loopCurrentEpisode()`` 一直是 seek + play，这里漏了后半句）。
    func restartFromBeginning() async {
        latestPosition = 0
        isFinished = false
        resumedFromText = ""
        if let activeProgressContext, let progressStore {
            await progressStore.clear(for: activeProgressContext.key)
        }
        guard let engine else {
            return
        }
        await engine.seek(to: 0)
        await engine.play()
    }
}
