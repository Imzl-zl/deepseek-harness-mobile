# 外观：壁纸与通透度

手机端的"背景 + 透明度"。**这是 DSH 没有的两项**（DSH 外观只有三档亮暗 + 字号字体），
属于手机侧自有的外观扩展；取舍与代价见
`.agents/notes/implemented/2026-10-31-wallpaper-and-surface-alpha.md`。

## 设置页两行

| 行 | 值 | 交互 |
|---|---|---|
| 背景 | `无` / `已设置` | sheet：从相册选一张 / 去掉背景（有壁纸时才出现） |
| 通透度 | `关闭` / `55%`–`99%` | sheet 内滑杆，**拖动即生效**（背后整页跟着变） |

两行在「通用」组里，紧跟在「主题」之后。

## 存储

- **壁纸**：`<App 私有目录>/files/appearance/wallpaper.img`，固定名、不带扩展名（格式由选图原生侧定，
  解码器按内容识别）。目录由 `sqflite` 的 `getDatabasesPath()` 父目录推出。
- **通透度**：`device.surface_alpha`，整数百分数 55–100（`data/ui_state.dart` 的 `UiKey.surfaceAlpha`）。
- **没有 `device.wallpaper` 键**：有没有壁纸由那张文件在不在决定，避免两份真值。

## 值域与遮罩

| 常量 | 值 | 作用 |
|---|---|---|
| `kSurfaceAlphaOpaque` | 1.0 | 不通透（等于未启用） |
| `kSurfaceAlphaMin` | 0.55 | 最通透下限；再低正文压不住 |
| `kSurfaceAlphaOnWallpaper` | 0.88 | 刚设壁纸时的默认通透度 |
| `kScrimOpacityMax` | 0.40 | 壁纸遮罩的最大不透明度 |
| `kGlassBlurSigma` | 20 | 输入栏毛玻璃的模糊半径（逻辑像素） |

遮罩不透明度 = `(1 − α) / (1 − 0.55) × 0.40`：通透度越低遮罩越轻，关闭时为 0。
深色主题压黑、浅色主题压白。常量都在 `app/lib/model/appearance.dart`。

## 渲染链

1. `main.dart` 的 `MaterialApp.builder` 包一层 `DshWallpaperLayer`：壁纸 → 遮罩 → 全部界面。
   所有路由与 sheet 都在它上面，换壁纸只需这一处。
2. 两个 `ThemeData` 都用 `DshTheme.dark/light(surfaceAlpha: α)`：`DshColorTokens.withSurfaceAlpha`
   派生一份色板，**只降 10 个表面色的 alpha**；文字 / 强调色 / 描边不动。
   `scaffoldBackgroundColor` 与 `colorScheme.surface` 用派生后的值，否则页面底色会把壁纸整块盖住。
3. 壁纸按屏幕像素宽解码（`ResizeImage.resizeIfNeeded`），独立 `RepaintBoundary`。
4. **毛玻璃只贴在输入栏一条**（`DshGlass`）：判据是 `context.dshColors.bgBase.a < 1`；
   表面不透明时不挂 `BackdropFilter`（模糊一块纯色是白花 GPU）。

## 边界

- **不做全屏实时模糊**：每帧对整窗口走高斯，滚动稳定掉帧。壁纸保持清晰。
- **不进协议**：壁纸与通透度是纯本地渲染，电脑侧不知道也不需要知道。
- **壁纸以 `ImageProvider` 进 UI**：`ui/` 不许 `import 'dart:io'`
  （`app/tools/verify-platform-boundary.mjs` 的 `ui-no-platform-import`）；读盘在
  `platform/wallpaper_store.dart`，装配层包成 `MemoryImage`。
- **选图另存一份**，不引用相册路径：权限被收回或原图被删时，引用会让壁纸某天变白。
- 保存前真解码一次；坏图不落盘，错误如实弹提示。

## 验证

- `cd app; flutter test test/appearance_test.dart` —— 夹取 / 落盘往返 / 遮罩 / **只降表面不降文字**。
- `node app/tools/verify-platform-boundary.mjs` —— 663 项。
- 真机：`flutter build apk --debug` + `adb install -r build\app\outputs\flutter-apk\app-debug.apk`。
