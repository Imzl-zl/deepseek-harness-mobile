# 设置行的值封顶 42%：长模型名不再把标题挤成竖排

- 日期：2026-11-06
- 状态：implemented
- 触发：真机截图（2026-11-05 20:01）设置页「当前模型」四个字竖排成一列。

## Problem

`_PrefRow` 把值放在 `ListTile.trailing`，而 `ListTile` 给 trailing 的是**固有宽度**
（`packages/flutter/lib/src/material/list_tile.dart:1515` 用 `iconConstraints` 量它），
再把标题的宽度紧到 `tileWidth - titleStart - adjustedTrailingWidth`
（同文件 `:1552-1558`）。值 `DeepSeek V4.1 Flash · WorkBuddy · magpie · workbuddy`
把这条预算吃光，标题只剩十几像素 —— 中文于是在任意字符处换行，显示成竖排。

## 判据（基线来自原型，不是这次另定的）

`mock/proto/styles.css` 的 `.settings-row`：

```css
.settings-row .row-copy  { flex: 1; min-width: 0; }
.settings-row .row-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.settings-row .row-value { max-width: 42%; overflow: hidden; text-overflow: ellipsis;
                           white-space: nowrap; text-align: right; }
```

即：**标题单行省略、值最多占行宽 42% 且单行省略**。落地端照抄这两条。

## 改法

- `_PrefRow` 从 `settings_page.dart` 抽成公开的 `SettingsRow`（`app/lib/ui/settings_row.dart`），
  自绘一行：图标 + `Expanded(标题, 单行省略)` + `ConstrainedBox(≤42% 行宽, 单行省略, 右对齐)`
  + 箭头；行高 14×2 + 20 = 48（与 `ListTile(dense: true)` 一致）。
- 17 个调用点 `_PrefRow(` → `SettingsRow(`；`settings_font_size_test` 里"把断言限定到这一行"
  的 finder 从 `find.byType(ListTile)` 改成 `find.byType(SettingsRow)`（行不再是 ListTile）。

## 被否的做法

- **`ListTile.trailing` 上加 `maxLines: 1`**：trailing 仍然按固有宽度排版，标题照样被压窄；
  只是从"竖排"变成"省略号"，根因没动。
- **值放 `subtitle`**：所有行都变两行，与基线的一行布局不符。
- **固定像素上限**（如 160）：不同屏宽下比例漂移，且与原型 42% 对不上。

## 代价

- 行的实现从 Material 的 `ListTile` 换成自绘 `InkWell + Row`：失去 `ListTile` 的
  `minVerticalPadding` 弹性（行高固定 48）与 `ListTile` 的语义容器；水波纹由 `InkWell` 提供。
- 值超过 42% 一律省略（模型 id 很长时只看得到前半段）——这是基线的既定取舍，不是本次新增。

## 验证

- 新增 `app/test/settings_row_test.dart`：390dp 与 320dp 两档，断言标题高度 < 30（旧实现是 4 行）、
  值 `maxLines == 1`、`overflow == ellipsis`、宽度 ≤ 42% 行宽。
- 变异：把 `* 0.42` 改成 `* 1.0` ⇒ 两条用例红（值宽 358 / 288）；还原后绿。
- `flutter test` 1761（+2）、`dart analyze --fatal-infos lib test` 0、`dart format` 0、
  settings 四组既有用例全过。
