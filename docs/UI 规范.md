# UI 规范（版本自适应：各系统用各自原生 UI）

## 一、总原则

1. **原生优先，不做跨版本仿制**：每个 iOS/iPadOS 版本都用**它自己那套原生 UI**呈现。
   - 不给 iOS 16+ 强行套 iOS 15 的样式，也不为「统一观感」而自绘系统控件。
   - 视觉与交互（导航栏、列表分组、工具栏、搜索栏、弹窗、上下文菜单、手势）全部交给系统。
2. **版本分支只允许出现在基础件里**：业务视图**不得**写 `#available` / `#if os(...)`；
   差异统一收敛到 `Packages/CatVodUI/Sources/CatVodUI/Platform/`。
3. **iOS 15 是下限**：凡 iOS 15 缺失的 API，必须提供该版本的**原生等价实现**（而不是自绘替代）。
4. **macOS 用 macOS 的外观**：不使用 iOS 专属样式（如 `.stack` 导航样式、`ToolbarItemPlacement.topBarLeading`）。
5. **没有公开 API 的能力就不做**（2026-10-11 用户拍板）：某个系统上缺**公开 API** 时，这个能力在那个系统上
   **不出现** —— 不摆假开关、不用私有 API、不去摸系统控件的内部实现。有公开 API 的版本照常做
   （分支仍只写在基础件里）。已按这条办的例子：iOS 15 的「按视图隐藏 Tab 栏」（M02P16，明着空操作）、
   iOS 15 的屏幕方向请求（要 iOS 16+ 的 `requestGeometryUpdate`）。

## 二、版本/平台映射（基础件已实现）

| 能力 | iOS 15 | iOS/iPadOS 16+ | macOS 13+ | 基础件 |
| --- | --- | --- | --- | --- |
| 导航容器 | `NavigationView` + `.stack` | `NavigationStack` | `NavigationStack` | `AdaptiveNavigationContainer` |
| 列表样式 | `.insetGrouped`（iOS 原生分组） | 同左 | `.inset`（macOS 原生） | `adaptiveListStyle()` |
| 工具栏 | `navigationBarItems` | `toolbar { ToolbarItem(.topBar…) }` | `toolbar { .navigation / .primaryAction }` | `adaptiveToolbar(leading:trailing:)` |
| 搜索栏 | `.searchable` + `.navigationBarDrawer(displayMode:.always)` | `.searchable`（新放置语义） | `.searchable` | `adaptiveSearchable(text:prompt:)` |
| 搜索栏（导航栏内嵌形态，参考录屏的搜索页） | `.toolbar` + `.principal` + `.topBarTrailing` | 同左 | 默认放置 + `.primaryAction`（macOS 无 `.principal`） | `adaptiveSearchBar(text:prompt:trailing:)` |
| 导航标题样式 | `.inline` 小标题（发现页版式） | 同左 | 原样（macOS 无该形态） | `adaptiveInlineNavigationTitle()` |
| 底部 Tab 栏按需隐藏 | **不支持**（iOS 15 无该原生 API，见 M02P16） | `.toolbar(.hidden, for: .tabBar)` | 不适用（macOS 的 `TabView` 不是底部标签栏） | `adaptiveTabBarHidden(_:)` |
| 画中画 / 后台继续出声（M26） | 系统内核：`AVKit.VideoPlayer` 底层是 `AVPlayerViewController`，配好会话与后台模式即由**系统**提供 PiP 与后台出声；自绘内核（MPV / FFmpeg）：**未做**（要帧拷贝层，公开 API 可行） | 同 iOS 15 | 由系统窗口那套管，不额外做 | `PlaybackAudioSession`（`AVAudioSession` 设 `.playback`）+ `UIBackgroundModes: [audio]` |
| 列表触摸的「旁听」信源（触发上一行的收放） | 同 iOS 16+（但栏本身不收，见上一行） | **给 `UIScrollView` 自己的 pan 加动作**（`addTarget`）—— 不挂自己的手势：iOS 16 上「旁听」手势会把滚动吃掉（M02P16 第六节） | 空操作（没有可收的栏） | `scrollTouchObserver(...)` |

后续会按需补充（仍遵循同一原则）：`NavigationSplitView`（iPad/Mac 双栏，iOS 16+/macOS 13+）、
`presentationDetents`（iOS 16+ 半屏弹层）、`@Observable`（iOS 17+；iOS 15/16 用 `ObservableObject`）、
`.scrollContentBackground`（iOS 16+）、`Grid`/`.gridCellColumns`（iOS 16+）、
系统设置页风格（iOS 的 `Form` + 分组；macOS 的 `Settings` 场景）。

> 已落地：**设置页**（M02P11）用 `List` + `adaptiveListStyle()`（iOS 的 `insetGrouped` / macOS 的 `inset`）
> 呈现系统设置那种分组形态，**不用 `Form`**：`Form` 在 macOS 上会退化成另一套观感，
> 与本规范「各系统用各自原生外观」的目标重复。

## 三、禁止事项

- ❌ 用 `UIDevice` 型号判断代替系统外观判断。
- ❌ 自绘导航栏/返回按钮/搜索框以「统一观感」。
- ❌ 在业务视图里散落 `#if os(iOS)` / `#available`。
- ❌ 使用 macOS 不可用的 iOS 专属 API（如 `.navigationViewStyle(.stack)`、`.listStyle(.insetGrouped)`）。
- ⚠️ `AnyView` 仅允许出现在需要按版本返回不同具体类型的适配函数里（如 `adaptiveSearchable`），业务视图不得使用。

> 例外说明：`#if canImport(...)` 用于「可选原生依赖」的能力探测（例如 `CatVodPlayer` 里的
> `#if canImport(Libmpv)` / `#if canImport(Libavformat)`），与本节的 UI 版本分支不是一回事，
> 它必须留在拥有该依赖的包内，并且**只能用于能力判定**（如 `PlayerEngineKind.isAvailable`），
> 不得用来切换 UI 呈现。

## 四、验收方式

- iOS 15 与最新 iOS 模拟器上各跑一遍：导航推进/返回、列表分组、工具栏按钮、搜索框位置与行为必须与系统习惯一致。
- macOS 13+ 上验证：窗口工具栏、列表风格、菜单与快捷键为 macOS 原生形态。
- 代码审查 + **本地闸门**：`Packages/CatVodUI/Sources/CatVodUI/Platform/` 之外不应出现版本分支 ——
  `Scripts/check_lint.py` 的 `platform_branch` 规则会拦（业务视图里写 `#available(` / `#if os(` 即命中；
  `#if canImport(...)` 不算，见上文例外说明）。
