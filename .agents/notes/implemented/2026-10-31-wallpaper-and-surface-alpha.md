# Agent Note: 壁纸与通透度（手机侧自有的外观扩展）

Status: implemented

## Problem

用户要"能换背景、能调透明度、看着通透"的那类外观。DSH 侧对照结论：

- 外观只有三档 `跟随系统 / 浅色 / 深色` 加字号字体（`packages/client/ui-theme/src/theme-settings.ts:9`），**没有背景与透明度**。
- 桌面那点通透来自 **macOS 窗口材质**：`titleBarStyle: 'hiddenInset'` + `vibrancy: 'sidebar'` + 透明 `backgroundColor`，模糊由系统给、页面只叠一层 tint（`apps/desktop/renderer/assets/window-material.css:3`；决策 `.agents/notes/archived/feature/2026-09-13-macos-hidden-titlebar-vibrancy.md`）。Windows / 网页版没有。
- 第三方主题插件能"换图"，靠的是往 web 渲染层注 CSS（`styles.insert(css)`，`packages/extensions/cordis-client-runner/src/client/evaluator.ts:89`）。这条路在 Flutter 侧没有对应物（没有 DOM、没有 CSS 引擎）。

所以这是**手机侧新增的一项外观偏好**，不是搬 DSH 的设置项，也不能靠"兼容主题插件"实现。

## Decision

1. **两项偏好，一个滑杆**：`背景`（相册选一张 / 去掉）与 `通透度`（55%–100%，100% 即"关闭"）。键只有 `device.surface_alpha`（整数百分数）；**有没有壁纸 = 那张文件在不在**，不另设键。
2. **壁纸落 App 私有目录**，由 `sqflite` 的 `getDatabasesPath()` 父目录推 `files/appearance/wallpaper.img`（`platform/wallpaper_store.dart`）。**不引 `path_provider`** —— 与 `platform/photo_picker.dart` 同一条：能不加走平台通道的第三方插件就不加（鸿蒙 fork 要能编过）。
3. **色板派生，而不是给每个 token 加 alpha**：`DshTheme.dark/light(surfaceAlpha:)` 先把两个 const 色板之一拿来，再经 `DshColorTokens.withSurfaceAlpha` 派生一份，**只降 10 个表面色的 alpha**（底 / 侧栏 / 三层 / 菜单 / 气泡 / 输入卡 / 代码块两块）。文字、强调色、描边一律不动。
4. **壁纸层挂在 `MaterialApp.builder`**（`ui/dsh_wallpaper.dart`）：壁纸 → 遮罩 → 全部界面。放在这一处，所有路由与 sheet 自动在它上面。
5. **遮罩随通透度反向增长**（0 → 0.40，`model/appearance.dart` 的 `scrimOpacityFor`），并可读性下限硬夹在 0.55。
6. **毛玻璃只贴在输入栏一条**（`ui/dsh_glass.dart`，`BackdropFilter`，σ=20），判据是"表面色半透明"（`c.bgBase.a < 1`）；不透明时不挂，避免每帧白花 GPU。
7. **设壁纸顺手把通透度调到 0.88**（`kSurfaceAlphaOnWallpaper`）：表面不透明时壁纸整张被盖住，不这么做就是"设了没反应"。

## Alternatives considered

1. **给 `DshColorTokens` 的每个字段加 alpha**
   - 最强理由：语义最直白 —— 表面色自己带透明度，调用方什么都不用知道。
   - 为何被否：`DshColorTokens._` 的 45 个字段要全部改成私有字段 + getter（命名参数不能以下划线开头，于是构造、两个具名构造、`copyWith`、`lerp` 一起动），而收益只是"少一层派生"。派生一份只在一个方法里，且色值真值源仍然只有两个 const 类。
2. **只做壁纸，不做通透度（表面保持不透明）**
   - 最强理由：零风险，不动色板一个字节。
   - 为何被否：表面不透明时壁纸被人为盖住，功能等于不存在；用户要的正是"通透"。
3. **全屏实时 `BackdropFilter`（连壁纸一起模糊）**
   - 最强理由：观感最接近系统级磨砂，滚动时背景跟着糊。
   - 为何被否：每帧对整窗口走一遍高斯，手机上滚动掉帧是稳定的；交互基线里毛玻璃本来也是局部用法（`mock/proto/styles.css:3620` 的 `.composer`）。要壁纸模糊就把图处理后再存，那是另一件事。
4. **不做遮罩，通透度完全自由**
   - 最强理由：用户想多透就多透，App 不该拦。
   - 为何被否：任意照片上正文必然出现成片读不出的区域（浅色风景毁深色主题、夜景毁浅色主题）。遮罩反向增长 + 0.55 下限是**功能**：把最坏情况压回可读区间；想更透就换一张图。
5. **导入 DSH 主题插件（颜色 token + 图标替换）做生态兼容**
   - 最强理由：能直接吃社区主题，省得自己做皮肤。
   - 为何被否：那份产物是 CSS 注入或 `tokens: Record<string,string>`（`api-catalog.ts:262-290`），Flutter 侧要么自带一个 CSS 值求值器加一个 JS 运行时，要么放弃；而插件里写死 `background-image: url(...)` 的那一类根本抽不出结构。本轮只做"壁纸 + 通透度"两件确定能做的事。

## Consequences

- 收益：外观自定义是纯本地渲染，不碰协议、不碰电脑侧；不新增任何依赖；色板仍只有一个真值源（两个 const 类 + 一处派生）。
- 代价 1：表面半透明后**层叠会透出下层**（卡片压卡片时看得见底图），这是通透的固有代价，不是 bug。
- 代价 2：**162 处表面色读取点全部受影响** —— 任何"表面是不透明色"的假设都要重新看（例如拿 `c.bgBase` 跟真机截图比像素的判据）。
- 代价 3：真机模糊只有输入栏一块，其余靠遮罩；全屏磨砂这条路没有走。
- 代价 4：壁纸字节常驻内存（按屏幕宽解码后约几 MB）；`MemoryImage` 的缓存键是字节散列，所以覆盖同一路径也一定换得出新图 —— 这是选它而不是 `FileImage` 的实际理由。
- 代价 5：`ui/` 不许 import `dart:io`（`app/tools/verify-platform-boundary.mjs` 的 `ui-no-platform-import` 当场抓过一次），所以壁纸以 `ImageProvider` 进 UI，"图从哪来"留在装配层。

## Testing

- `app/test/appearance_test.dart`：夹取（含 NaN）／整数百分数往返／遮罩两端与单调性／**"只降表面不降文字"**（`bgBase.a` 变、`labelPrimary.a` 仍是 1）／浅色套同样。
- `node app/tools/verify-platform-boundary.mjs`：663 项全绿（曾因 `ui/dsh_wallpaper.dart` 里 `import 'dart:io'` 红过一次，改成传 `ImageProvider`）。
- `app/test/settings_sync_test.dart` 的"设置页三行"按视口顺序重排断言：新增两行 + 一行说明把下面两行推到首屏之外，原来"一屏全在"的假设不再成立（懒建列表）。
- 真机（`23113RKC6C`，Android API 36）：`flutter build apk --debug` + `adb install -r` 原地替换，保留配对凭据。
