# P1 后半第 3 批：预览族走 `HostRpc`（`data` 的 wire import 3 文件 → 2 文件）

- 日期：2026-11-06
- 状态：implemented（**第 3 批 / 共 4 批**；只剩收尾）
- 前情：第 1 批（会话族）`…-batch1-session-family.md`、第 2 批（目录族）
  `…-batch2-catalog-family.md`、端口形状的复盘 `…-hostrpc-holder.md`。

## Problem

预览族的四个读口仍由 `data/` 直接调 `wire/`：

| 位置 | 认的是什么 |
|---|---|
| `app_model.dart` | `file.list`（目录列举）、`file.changes`（改动记录） |
| `file_preview.dart`（**2 条 wire import**） | `file.read`（分页正文）、`file.diff`（逐行比对） |

## Decision

1. **不搬 DTO**：四个读口回的已经是 `model/` 的类型（`FileListing` / `FilePage` /
   `ChangesSummary` / `FileDiff`）—— 这一批只搬**调用口**。
2. `HostRpc` 加四个方法：`fileListing` / `filePage` / `changesSummary` / `fileDiff`。
   四个都**没有摘要三态**（与对应 `loadXxx` 一致，读不出就是 `null`）：计数与出声仍在
   `wire/` 的 `valueOrReport` 那一处，端口不复制这条判据。
3. `WireHostRpc` 四个一行转发；`file_preview.dart` 加 `HostRpc get _rpc => hostRpcOf(client)`
   （判据仍只有一处），`app_model` 的两个读口改 `_rpc`。
4. 两条 import 随之删除（`wire/rpc/file.dart` / `wire/rpc/changes.dart` 在 `app_model`
   里再没有别的用处）。

## 代价与留下的边界

- **`file_preview.dart` 不再 import `wire/`** —— `data/` 现在只剩 `app_model` 与
  `projection.dart` 还认线上形状。
- 没有新增文件、没有搬类型，所以 boundary 的项数与文件数都不变（791 / 183）。
- 剩下的 `data → wire` 是**收尾批**：`app_model` 的写操作（create / fork / select-model /
  cancel / update-queue / prompt、`interaction.respond`、插件启停与安装、工作区四个动作、
  `settings.update`、`usage.summary`、`endpoint.describe`、`job.*`、mention 候选），
  以及 `projection.dart` 那一条（与 `projectEvent` 的 55 处调用点绑在一起，单独一批）。

## 验证

- `cd app; dart analyze --fatal-infos lib test` → No issues found；
  `dart analyze --fatal-infos integration_test` → No issues found。
- `cd app; flutter test` → **1759** 全过（同数）。
- `node app/tools/verify-platform-boundary.mjs` → **791** 项全过（183 个 Dart 文件，未变）。
- `node app/tools/verify-rpc-single-caller.mjs` → PASS。
- `dart format --output=none --set-exit-if-changed lib test integration_test` → 0。
- `git grep -c "import '\.\./wire/" -- app/lib/data` → **3 个文件 / 16 条 → 2 个文件 / 12 条**：
  `app_model` 13 → **11**、`file_preview` 2 → **0**（不再出现在清单里）、`projection` 1 不动；
  `-- app/lib/core` 仍 **0**。
- `app_model.dart` 里 `wire.` 出现次数：29 → **27**。
- **变异校验**：`WireHostRpc.filePage` 改成恒返回 `null` ⇒
  `files_page_test` + `chat_file_mention_test` + `changes_card_test` 三个文件 **4 条红**
  （共 32 条）；还原后 32 条全绿。
