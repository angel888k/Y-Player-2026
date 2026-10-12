import Foundation

/// 片头 / 片尾的规则（M03P16，逐条对齐上游 FongMi/TV）。
///
/// 上游口径（`VideoActivity.onOpening/onEnding`、`PlayerManager.canSetOpening/canSetEnding`、
/// `Constant.getOpEdLimit`、`VodHistoryPolicy.startPositionMs`、`VodPlaybackController.onTimeChanged`）：
///
/// | 上游 | 含义 |
/// | --- | --- |
/// | `opening` = 标记时的**当前位置** | 「片头」标的是**跳到哪**（片头结束处） |
/// | `ending` = `duration - 标记时的位置` | 「片尾」标的是**还剩多久** |
/// | 只能在两端附近标（`getOpEdLimit`） | <15 分钟 → 3 分钟；<30 分钟 → 6 分钟；其余 → 10 分钟 |
/// | 起播位置 `max(opening, position)` | 片头与上次位置，取靠后的那个 |
/// | `ending > 0 && position + ending >= duration` → 下一集 | 播到片尾就跳 |
enum PlaybackOpeningEndingRules {
    /// 两端各留多长的可标记范围（上游 `Constant.getOpEdLimit`，分钟换成秒）。
    static func limit(duration: Double) -> Double {
        if duration < 15 * 60 {
            return 3 * 60
        }
        if duration < 30 * 60 {
            return 6 * 60
        }
        return 10 * 60
    }

    /// 当前位置能不能标「片头」（上游 `PlayerManager.canSetOpening`）。
    static func canSetOpening(position: Double, duration: Double) -> Bool {
        position > 0 && duration > 0 && position <= limit(duration: duration)
    }

    /// 当前位置能不能标「片尾」（上游 `PlayerManager.canSetEnding`）。
    ///
    /// 比上游多一道 `tail > 0`：0 在我们这里是「没标」—— 在最后那一刻标会写出一个 0，
    /// 界面上看起来「点了没反应」，不如直接不给标（M03P16 首验把这条钉进单测）。
    static func canSetEnding(position: Double, duration: Double) -> Bool {
        let tail = duration - position
        return position > 0 && duration > 0 && tail > 0 && tail <= limit(duration: duration)
    }

    /// 起播位置（上游 `VodHistoryPolicy.startPositionMs`）：片头与上次位置，取靠后的那个。
    static func startPosition(opening: Double, resume: Double) -> Double {
        max(opening, resume)
    }

    /// 这份进度记录能不能拿来续播（**纯函数**，有单测）：只有「记录那一集 == 现在这一集」才谈得上。
    ///
    /// 为什么要有它（M28P10，用户报「选集播放或者下一集播放应该是从头播放」）：进度是**按片**记的
    /// （键 = 站点 + 影片），集下标存在记录里 —— 换集之后拿到的还是上一集的记录，位置与片头/片尾
    /// 标记全都不属于这一集：照用就会「切过去直接跳到上一集看到的位置」，甚至被上一集的片尾标记
    /// 当场带走。`-1`（未知）一律不认 —— 宁可从头播，也别猜。
    static func isSameEpisode(savedEpisodeIndex: Int, currentEpisodeIndex: Int) -> Bool {
        savedEpisodeIndex >= 0 && savedEpisodeIndex == currentEpisodeIndex
    }

    /// 该不该跳片尾（上游 `VodPlaybackController.onTimeChanged`）：标了片尾、且已经播到那儿。
    static func shouldSkipEnding(position: Double, duration: Double, ending: Double) -> Bool {
        ending > 0 && duration > 0 && position + ending >= duration
    }
}
