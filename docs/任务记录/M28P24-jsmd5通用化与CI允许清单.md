# M28P24 `.js.md5` 接口通用化 + CI 在虚拟机上只跑「允许清单」

- 状态：**已改**（本地闸门全绿；CI run 38351179493 全绿：7 包单测 + iOS/macOS 构建 + IPA）
- 时间：2026-10-13
- 触发：用户两项 —— ①「.js.md5 后缀的接口导入后都要能正常使用（现在不是通用的）」；
  ②「用 GitHub 的 CI 验证」。

## 一、`.js.md5` 三类不通用（已修）

原始问题：只有「`xxx.js.md5`、无查询串、md5sum 文本写法」这一种形态认得出。

改动（`743da96`）：

- `ConfigLocator.javascriptURLDroppingDigestSuffix` / `digestURL(for:)` 改成「路径 + 查询串」切分：
  - `…/index.js.md5?v=3` → 脚本 `…/index.js?v=3`、校验 `…/index.js.md5?v=3`；
  - `…/index.js?v=3` → 校验地址 = `…/index.js.md5?v=3`；
  - 后缀大小写不敏感（`.JS.MD5` 也认）。
- `MD5.firstDigest(in:)`（`MD5Digest.swift`）：`.md5` 端点回 md5sum 风格（`<hash>  index.js`）
  或 JSON 都能抠出摘要。
- 测试：`ConfigLocatorTests` 新增 3 条；`SourceRepositoryJavaScriptTests` 新增 1 条
  （`StubTransport`，key 用 `jsURL + ".md5?v=3"` / `jsURL + "?v=3"`）。

## 二、CI 在虚拟机上挂死（已修）

背景：GitHub macOS 运行器是虚拟机。6 小时挂死两次（10/12，`CatVodPlayer tests` 步骤，
日志停在 `IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver`）。

处理分两层：

1. **真实影音栈套件在 CI 跳过**（`743da96` + `bfbea19`）：8 个套件加
   `.enabled(if: VideoStackAvailability.isUsable, "CI 跳过：GitHub 运行器没有硬件视频栈")`
   （`VideoStackAvailability` 判 `GITHUB_ACTIONS`）：LibavInput / LibavVideoDecoder /
   LibavAudioDecoder / LibavFFmpegSession / SystemPlaybackStatsEndToEnd / SystemPlayerRate /
   SystemPlayerTracks / SystemVideoSurface。本地照跑。
2. **探针矩阵定位剩余挂点**（探针分支 `ci/probe-catvodplayer` + `probe-catvodplayer.yml`，
   run 38345935613，6 组并行、12 分钟超时）：

   | 组 | 过滤 | 结果 |
   |----|------|------|
   | A-pure | PlaybackScaleMode / SpeedSetting / MpvEventMapping | ✅ 22 条 / 3 套件 |
   | B-ffmpeg-avail | FFmpegAvailability / FFmpegEngine / FeedStarvationWatchdog | ✅ 17 条 / 3 套件 |
   | C-mpv-engine | MpvEngineTests | ❌ 构建完成后零测试输出，挂到 12 分钟超时 |
   | D-mpv-avail | MpvAvailabilityTests | ✅ 3 条 / 1 套件 |
   | E-system | PlayerSettings / PlaybackStats | ✅ 27 条 / 5 套件（含 SystemStats* 两个纯映射套件） |
   | F-libav-rest | LibavAudioRenderer / AudioSampleBuffer / SampleBuffer / SubtitleDecoder / VideoRenderer | ✅ 9 条 / 5 套件 |

3. main 全量跑（run 38345280318）复现：`104 条 started / 0 条 completed`，一直挂到
   20 分钟**步级超时**兜底被杀 —— 证明「只跳过 8 个套件」不够，`MpvEngineTests` 会把整个
   测试进程挂死。
4. **终修（`a512fef`）**：build.yml 的 CatVodPlayer 步骤改**允许清单**
   （`--filter` 16 个套件 = A/B/D/E/F 并集，含 SystemStats* 两个纯映射套件）；
   `MpvEngineTests` 留在本地全量（`Scripts/release-macos.sh`）；20 分钟步级超时保留作兜底
   （实测生效，run 38345280318：`The action 'CatVodPlayer tests' has timed out after 20 minutes`）。
   - 坑（供后人）：swift-testing 的**过滤词对「同文件套件」也生效** ——
     `SystemPlaybackStatsTests.swift` 一个文件三个套件，过滤 `PlaybackStatsTests` 会三个一起命中。
     允许清单已按「文件 + 类型名」两个口径核对，`MpvEngineTests` 不被任何词命中。
   - 新增套件的规矩：本地先过全量，再走探针流程验证虚拟机安全，然后加进清单。

## 三、验证

- CI：run 38351179493 **全绿**（Lint / 7 包单测 / iOS+macOS 构建 / 未签名 IPA；
  CatVodPlayer 78 条 16 套件 52 秒，CatVodUI 388 条 75 套件，Release 作业按设计分支跳过）。
- 上机（用户 Mac）：导入 `…/index.js.md5` 形态接口 → 站点出现、能搜能播；
  变体 `…/index.js.md5?v=…`、`…/index.js?v=…`（自动补 `.md5` 校验）同验。
