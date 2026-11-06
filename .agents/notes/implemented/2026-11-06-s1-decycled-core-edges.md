# S1 去环：先把三条逆流边消掉（DiffLine / fieldOf / 字号值域）

- 日期：2026-11-06
- 触发：架构审查（`.agents/notes/proposed/2026-11-06-branch-a-and-pr-audit.md`）把逆流依赖
  列成 S1 的第一件事：`ui → core/model`、`data → model`、`core` 零平台依赖这三条方向之外，
  当时实测有 6 条反向 import。
- 状态：implemented

## Problem

`git grep "import"` 实测（不猜）：core→wire 2、data→wire 21、ui→wire 2、wire→core 0、
data→model 38、model→data 1、model→ui 2、theme→model 1。

`data → model` 与 `ui → wire` 是**允许方向**（设计文档的分层就是这样）。反向的四条才是问题：

| 反向边 | 具体 import |
|---|---|
| model → ui ×2 | `model/diff.dart:21`、`model/file_diff.dart:16` → `../ui/dsh_diff.dart`（为了 `DiffLine` / `DiffKind`） |
| model → data ×1 | `model/permission.dart:35` → `../data/projection.dart`（为了 `fieldOf`） |
| theme → model ×1 | `theme/dsh_type.dart:39` → `../model/preferences.dart`（为了字号上下界） |

代价不是洁癖：`model/` 与 `theme/` 本该是纯 Dart 可单测的层，而 `ui/dsh_diff.dart`
import 了 `package:flutter/material.dart` —— 逆流 import 把它一路带进模型。

## Decision

1. **`DiffLine` / `DiffKind` 搬进 `app/lib/model/diff_line.dart`**。形状跟着**生产者**
   （`model/diff.dart` 折行、`model/file_diff.dart` 过线），渲染者 `ui/dsh_diff.dart`
   只画。几何（40px 行号槽、sticky 左列）留在 ui —— 那是画法，不是数据。
   测试里 `import 'ui/dsh_diff.dart' show DiffKind` 改成 import `model/diff_line.dart`。
2. **`fieldOf` / `stringField` / `intField` / `nonEmptyString` 搬进 `app/lib/core/json_field.dart`**，
   `data/projection.dart` 与 `model/permission.dart` 都从 core 取。
3. **字号值域（正文 10–22 / 默认 14 / 四档倍率 / 四档名字 / 默认档）搬进
   `app/lib/core/type_scale.dart`**：三层同时读（theme 换算、data 读盘 clamp、ui 设置行），
   而 `theme/` 依赖 widgets、`data/` 又不许 import widgets ⇒ core 是唯一的共同底。
   四档名字与倍率一一对应，分开就会漂移（`type_scale_test.dart` 钉着长度相等），所以一起搬。

## 被否掉的

- **在 `ui/dsh_diff.dart` 里 `export '../model/diff_line.dart'`**：看起来省一个 import，
  实际把真家藏起来，下一次又有人从 ui import 回来。
- **把 `fieldOf` 复制进 `model/`**：`fieldOf` 已经在 `core/items.dart`、
  `wire/rpc/projections.dart`、`model/goal.dart` 各有一份私有拷贝，再复制就是第四份。
- **把字号常量放 `theme/`**：`data/app_model.dart` 要读它，而 data 不许 import widgets。
- **把 panel / 设置行的文案也搬 core**：只搬"与档位一一对应、三层都要读"的那几项；
  其余用户文案仍留在它自己的层。

## 本批没动

`core → wire`（2 处：`core/items.dart:15` 的 `wire/events.dart`、
`core/sync_client_impl.dart:24` 的 `wire/rpc/session_page.dart`）与 `data → wire`（21 处）
**留着**：消它要的是"core 声明接口、wire 实现"的依赖倒置，动的是收帧热路径，
必须单独一批 + 单独笔记（S1 后半）。

## 验证

- `dart analyze --fatal-infos lib test`：No issues found。
- `flutter test`：**1735 / 1735 通过**（本批挪了三个文件、改了 8 处 import，没有行为变化）。
- `node app/tools/verify-platform-boundary.mjs`：732 项全过（扫描文件数 167 → 168）。
