import SwiftUI

/// 播放页的「弹幕设置」快捷面板（M03P24，对齐上游 `DanmakuSettingDialog`）。
///
/// 上游那条：播放页的弹幕按钮开一张**半屏** bottom sheet（`getMaxHeight() = 屏高 / 2`），
/// 里面是「外观 / 时间 / 密度 / 显示」四页，改哪一项都当场生效（`player.setDanmakuConfig(...)`）。
/// 我们这版把上游那几十个旋钮收成自己那份配置的五项（显示 / 字号 / 透明度 / 速度 / 区域），
/// 与设置页「弹幕显示」**共用同一组控件**（``DanmakuDisplayControls``）—— 两个面一样，
/// 才不会有「设置页调的跟播放页调的不一样」。播放页不认识 `AppModel`，配置靠宿主给的绑定回写。
///
/// 这张面的**头归系统**（M28 首验之二十五）：标题走 `navigationTitle`、「完成」走工具栏、
/// 「恢复默认」是列表里的一行 —— 原先那条自绘头与 `docs/UI 规范.md` 总则一冲突。
struct PlaybackDanmakuSettings: View {
    /// 要改的那份配置（宿主给的绑定：读的是 `AppModel.danmakuDisplay`，写回也回它）。
    @Binding var config: DanmakuDisplayConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AdaptiveNavigationContainer {
            List {
                // 半屏里不写解释文字：地方不够，带说明的那份在设置页。
                DanmakuDisplayControls(config: $config, showsExplanations: false)
                // 「恢复默认」是列表里的一行（M28 首验之二十五：头归系统，工具按钮不挤在工具栏里）。
                Section {
                    Button("恢复默认") {
                        DanmakuDisplayBindings(config: $config).reset()
                    }
                }
            }
            .adaptiveListStyle()
            .navigationTitle("弹幕设置")
            .adaptiveInlineNavigationTitle()
            .adaptiveToolbar {
                EmptyView()
            } trailing: {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}
