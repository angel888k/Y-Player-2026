import CatVodStore
import SwiftUI

/// 播放页的「线路」区（M03P17）：原地换线路，接着看同一集。
///
/// 对齐上游播放页的线路条（`mBinding.flag` + `mVod.selectFlag`：换线路时按集名找同一集继续播）。
/// 换完与换集走同一个落点（`applyEpisode`）：同一个引擎重新 load，位置靠进度记录续上。
///
/// 拆出去的理由同 `+Speed` / `+OpeningEnding`：`PlaybackView.swift` 的行数贴着 `file_length` error（800）。
extension PlaybackView {
    /// 「线路」区：只有拿得到线路清单、且不止一条线路时才出现。
    @ViewBuilder
    var lineSection: some View {
        if let lineSwitcher, lineSwitcher.lines.count > 1 {
            Section("线路") {
                Picker("线路", selection: lineBinding) {
                    ForEach(lineSwitcher.lines, id: \.self) { line in
                        Text(line).tag(line)
                    }
                }
            }
        }
    }

    /// 线路选择：换线路是**异步重载**，所以绑定只派活（真正的活在 `switchLine(to:)` 里）。
    private var lineBinding: Binding<String> {
        Binding(
            get: { selectedLine },
            set: { newValue in
                guard newValue != selectedLine else {
                    return
                }
                Task { await switchLine(to: newValue) }
            }
        )
    }

    /// 换线路：取「另一条线路上的同一集」→ 先落一次进度 → 原地换（同一个引擎）。
    ///
    /// 失败如实说：目标线路上没有那一集 / 拿不到地址 → 提示并**留在原线路**（不硬编一个地址）。
    func switchLine(to line: String) async {
        guard let lineSwitcher, line != selectedLine else {
            return
        }
        let index = currentEpisodeIndex ?? playlist?.currentIndex ?? 0
        let episodeName = activeProgressContext?.metadata.episodeName ?? ""
        // 先把当前位置写下去：换完线路 resume 的就是它（`resumableResource()` 走进度记录）。
        await persist(force: true)
        guard let next = await lineSwitcher.load(line, episodeName, index) else {
            errorText = "「\(line)」上没有找到这一集，换线路没成。"
            return
        }
        // 同一集在两条线路上的**下标可能不同**（按集名对的），而续播判定看的是「记录里的集下标
        // == 现在选集的下标」—— 按新线路的下标把这份位置重记一次，换线路才不会被判成换集（M28P10）。
        // `progressContext` 是可选的（没有进度键时整条播放都不记进度）：拿不到就不重记，照旧走。
        if let newIndex = next.progressContext?.episodeIndex {
            await persist(force: true, episodeIndexOverride: newIndex)
        }
        selectedLine = line
        lineSwitcher.onLineChanged?(line)
        await applyEpisode(next, fallbackTitle: activeTitle, episodeName: episodeName)
    }
}
