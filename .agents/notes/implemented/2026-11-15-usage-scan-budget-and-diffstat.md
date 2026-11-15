# Agent Note: 改动行数不再显示 0 —— 空 `diffs` 的 `write` 回退到参数；用量活动按时间预算扫

Status: implemented

## Problem

用户 2026-11-15 的两条反馈是同一个形态：**数字显示成"没有变化"，而事实是变了**。

1. 「桌面执行编辑啥的修改了那个变化，app 上显示 0，我以为出错了；我看桌面不是 0，确实改了」
   —— 工具卡右上角的 `+N −M` 在**写新文件**时是 `+0 −0`。
2. 「用量页有时候加载不出来，加载半天还会报错」—— 活动那一段要转很久，偶尔一句报错收场。

### 事实一：`write` 创建文件时宿主的 `meta.diffs` 是空数组

本机会话日志（按帧解压 `session.v4.jsonl.zstd`）里 `write` 建两篇笔记的结果：

```json
"meta": { "operation": "create", "path": "…", "diffs": [] }
```

宿主的原因在它自己的源码里：`packages/fs/tool-fs/src/write.ts:103-110` 的
`presentationMeta` 是 `value.before === null ? [] : computeHunkDiffs(...)` ——
创建文件没有旧文本可比，**一个 hunk 都没有**。

手机只读 `meta.diffs`，`toolResultViewOf` 的守卫是 `hunks.isEmpty && path.isEmpty ⇒ null`，
而 `path` 非空 ⇒ 继续走 ⇒ `added = removed = 0` ⇒ 画出 `+0 −0`。
桌面在 `ui-tool/src/client/tool/models/diff-card-model.ts:113-116` 有回退规则：
**空 diffs 的 `write` 退回调用参数里的 `content`（整份新增）；空 diffs 的 `edit` 整块不画。**

### 事实二：活动按"条数"分批，把整份聚合重做了 130 次

`usage.summary {days}` 要按天算活动就得读每个会话的 `trajectory` 投影，连接器从前是
`DAY_SCAN_BATCH = 4`（每次请求只新扫 4 个），手机 350 ms 要下一批。本机实测：

| 量 | 值 |
|---|---|
| 会话总数 / 60 天窗口内 | **517 / 517**（全部在窗口内） |
| 这些会话的日志 | **670.7 MB** |
| 宿主投影缓存 | 794 文件 / 48.4 MB（全量解析 1.8 s） |
| 按"一次 4 个" | **130 个来回** |

每个来回都重做一遍 `sessions.list()` + 别名 + 总量 + 项目 + 会话榜，而手机只读
`byDay` 与 `daysProgress` 两样 —— 前缀工作被重复 130 次。并且那一批用 `Promise.all`：
**任何一个会话读失败，整个 `usage.summary` 就失败**，手机把它写成一句
"拉取用量汇总失败"，补批的 `Timer` 也停在成功分支之外，于是页面就停在报错上。

## Decision

两条判据都照宿主搬，不再自己发明：

1. **改动行数**：按 DSH `diffCardModel` 的三档走 —— 失败 ⇒ 不画；有应用后的 hunks ⇒ 用它折；
   hunks 为空 ⇒ **只有 `write` 回退到调用参数**（整份算新增），`edit` 与其余工具不画。
   运行中的调用也按参数先显示（`:110`）。
2. **活动扫描**：按**时间预算**分批（`DAY_SCAN_BUDGET_MS = 1500`，并发 4），
   失败隔离到单会话（`Promise.allSettled` + 新字段 `daysFailed`），
   且**失败也算"试过"**（`scanned` 按 `attempted` 走），保证进度单调并终将走完。

准入判据（可机械判定）：

1. `write` 建文件（`meta.diffs: []`）的卡片行数是**整份内容新增**，不是 `+0 −0`；
   算不出来（无调用、无合并载荷）时**不显示**，不摆 `+0 −0`。
2. `edit` 的空 diffs、失败的结果：`diffStat` 必须是 `null`（不画）。
3. 没有专用卡的工具（`apply_patch` 等）的行数与 `edit` 同口径（线级折，不是两段文本行数相加）。
4. `usage.summary {days}` 一趟之内扫得完就扫完；扫不完时报 `daysProgress`，
   失败的会话数进 `daysFailed`，且**进度不倒退、最终等于 total**。

## 验证（2026-11-15）

- `cd app && flutter test` → **1941** 项全绿（新增 9：改动行数 7 + `daysFailed` 2）。
- `cd connector && pnpm exec tsx --test tests/usage-summary.test.ts` → **23** 项全绿
  （原 20；改 1 条旧契约"一次 4 个"、新增 2 条）。时间预算那条分支用 `node:test` 的
  mock `Date` 做成确定性：每读一个会话推进 400 ms ⇒ 一批 4 个 = 1.6 s > 1.5 s 预算。
- **变异校验**（各恰好红对应用例）：
  ① 拆掉 `write` 的空 diffs 回退 ⇒ 2 条红（建文件 / 冷启动合并载荷）；
  ② 把"失败不画"改成花一个 `+0 −0` ⇒ 1 条红；
  ③ 扫描循环只跑一批 ⇒ 1 条红（"一趟尽量扫完"）；
  ④ 让失败的读重新抛出 ⇒ 1 条红（"一个会话读不出来不影响整页"）。
- 门禁：`verify-platform-boundary` 945 项、`verify-size` 通过（两处预算按规矩抬数并写明理由）、
  `verify-rpc-single-caller` 通过、`verify-icons` / `verify-tool-paths` 通过、connector `pnpm test` 862 项。

## Alternatives considered

1. **裁掉 `days` 应答里的总量字段**（每趟只回 `{byDay, daysProgress}`，省掉重复聚合）
   - 最强的理由：这是"重复做前缀工作"最直接的消除，一趟能省掉 `sessions.list()` 与整份聚合。
   - 为何被否：手机 `UsageSummary.fromWire` 要求 `sessions` / `grandTotalTokens` 在场，
     裁掉就得让同一个方法有两种形状、`readUsageSummary` 多一个分叉；而按时间预算之后
     一共才几趟，省下的不够抵这份复杂度。会话数再涨一个量级时该回来做。
2. **把按天缓存落盘**（`dayCache` 现在每进程一份，宿主重启即失效）
   - 最强的理由：冷启动那一趟会重扫 517 个会话，落盘能让第二次启动直接命中。
   - 为何被否：那是新增一个会过期、要 schema / 迁移 / 清理的第二真值源；按时间预算之后
     冷启动那一趟本身就是几秒。留作后手，不在这轮。
3. **给每个请求加超时**（"转太久就失败"）
   - 最强的理由：用户感受到的就是"转很久"，加个上限至少不会无限等。
   - 为何被否：通道层刻意**不在每请求上加超时**（`core/endpoint_transport.dart:96`）——
     请求失败的语义是"这条连接没了"，不是"等太久"，两者客户端动作不同。
     慢要修在"少做重复工作"上，不是加一个到点就报错的档。
4. **`write` 创建文件时把整份内容当 diff 正文画出来**（与桌面完全一致）
   - 最强的理由：桌面上就是这么画的，行数与正文同源，最不容易自相矛盾。
   - 为何被否：那要求把整个文件内容留在条目上（还会进 sqlite），与
     `data/projection.dart` 里"不留 `arguments`"的既有取舍直接冲突 ——
     会话里写过的每个文件会再存一份。手机只要数字。

## Consequences

- 收益：
  - 工具卡的 `+N −0` 与桌面同口径，且**运行中就能看见**（不必等结果）。
  - 用量活动从"130 个来回"降到"几趟"；单个会话读失败不再毁掉整页，
    代价以 `daysFailed` 明说（页面写"有 N 个会话读不出来，活动统计不含它们"）。
  - 顺手收掉一处"同一件事两处算"：`diffStatOf` 与 `diffStatOfTexts` 现在是同一口径
    （从前 `{a,b}→{a,c}` 在 `apply_patch` 卡上算 `+2 −2`、在 `edit` 卡上算 `+1 −1`）。
- 代价：
  - 创建文件时手机**只给数字、不画正文**（有意偏离，见上）。
  - `data/app_model.dart` +9 行、`ui/usage_page.dart` +34 行，两处尺寸预算按规矩抬数
    （5204 → 5213、1600 → 1634，理由写在 `app/tools/verify-size.mjs` 的表里）。
  - 每趟仍重算总量（Alternatives 1 的残余）；`dayCache` 仍是每进程的。
  - **没有真机量过**这次的实际耗时：517 会话 / 670 MB 是事实，"几趟"是从预算算出来的。
