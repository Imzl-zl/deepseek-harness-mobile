# wire/rpc 评审后的修复：一条失败通道、一份合并规则、一个信封入口

- 日期：2026-10-26
- 状态：proposed
- 范围：`5428fba^..96d4448`（上一轮 RPC 应答面收口的 51 个文件）的评审结论
- 相关：`implemented/2026-10-25-wire-rpc-layer-layout.md`（层形状与批次）、
  `implemented/2026-10-25-wire-design-review.md`（五判据与被否方案）、
  `implemented/2026-10-25-wire-golden-and-session-list.md`（金样机器）、
  `implemented/2026-10-15-projections-envelope-must-be-unwrapped.md`（第二次事故）

## Problem

上一轮把 RPC 应答的解码收进了 `wire/rpc/`，结构成立（17 个面文件、43 个金样方法、
`data/`+`ui/` 零 `client.call<`）。但评审发现：**收口只覆盖了"形状在哪读"，
没覆盖"失败走哪条路"与"同一规则是否只有一份"**，于是出现下面六类问题。
它们不是风格问题，每一类都能让门禁全绿而线上静默。

1. **页级失败分成两条通道（真回归）**。`readSessionPage` 对"refetch 标记缺 seq"
   抛 `SessionPageShapeError`（`app/lib/wire/rpc/session_page.dart:109`），
   而 `SyncClientImpl.page()` 只 `on ProtocolException`（`app/lib/core/sync_client_impl.dart:973`）。
   改动前同一个位置抛的是 `ProtocolException(badFrame)`（`6aaefc4^:1006`），会被接住并填
   `failure`；现在异常穿出 `page()`，`loadOlderHistory` 只有 `try/finally`
   （`app/lib/data/app_model.dart:3044`），调用点是 `unawaited(...)`
   （`app/lib/ui/chat_page.dart:2961`）⇒ 未处理异步错误、`historyFailure` 不置位，
   界面表现是"上滑翻页毫无反应"。同文件 `:23` 的注释还写着"由连接层折成整页失败"——
   注释描述的是期望，不是事实。
2. **缺陷 3（job 快照回退）没有回归网**。`_mergeJobSnapshot`
   （`app/lib/data/app_model.dart:990-1002`）只在 `refreshJobs` 里调用，而所有用例
   每条只喂一次快照；提交里点名的那条用例走的是 `status` 帧，不经过合并路径。
   把合并逻辑删掉，全仓仍绿。
3. **生产者无条件写出的键被当成"可选 + 默认值"**。`JobRowView` 的
   `label`/`status`/`startedAt`/`outputTotal` 是必填
   （`connector/src/protocol/job-output.ts:54-67`，`dsh/jobs.ts:47-59` 无条件写出），
   解码器却写成 `optional* + ?? 默认`（`app/lib/wire/rpc/job.dart:97-100`），
   其中 `status ?? 'running'` 正是缺陷 3 要消灭的"永远转"形态，且不计数。
   `session.page` 的 `hasMore`、`workspace.list` 的 `path`/`createdAt` 是同一形态。
   这与 `session.dart` 自己写的判据（"必填/可选看生产方式"）相反。
4. **门禁范围窄于它声称的不变量**。设计评审写的是"`app/lib/` 除 `wire/rpc/` 外
   零 `client.call<`"（`2026-10-25-wire-design-review.md:152`），脚本只扫
   `app/lib/data` 与 `app/lib/ui`（`app/tools/verify-rpc-single-caller.mjs:24`）；
   `core/sync_client_impl.dart` 里还有 4 个方法名。同一篇笔记 `:267` 说
   page/refetch"根本不是 `call<`"，而 `:951`、`:1017` 就是 `call<Object?>`——
   事实写错，下一个人会按错的理由推理。
5. **"同一件事一份实现"在层内被打破**。`flatValues` 零使用
   （`app/lib/wire/fields.dart:198`），`projections.dart` 自己判类型；
   `{key: [...]}` 信封在 6 个面各写一遍；`_modelSelectionOf`/`_modelRefOf` 在
   `session.dart` 与 `projections.dart` 近乎逐字重复；`has` / `requireList` /
   `readReceipt` 是死代码。这正是布局笔记立论要消灭的形态。
6. **收尾缺口**：19 处代码回指指向已移入 `implemented/` 的 `proposed/` 路径；
   `permission.switch` 复制了 `command.execute` 的解码（注释却写"解码器只有一个"）；
   `agentPresets.list` 是唯一"有金样、App 侧零断言、不计数"的方法；
   同一缺陷在 `_idsOf` 会被计两次。

## Decision

四条裁定，后面每一批都服从它们：

- **失败只有一条通道**：解码器只回 `WireReading`，不再抛自定义异常；
  "整页读不出来"是 `WireBad`，由调用方映射成 `SessionPage.failure`。
  **门槛**：`app/lib/wire/` 里不出现 `throw`（`WireFieldError` 只由 `fields.dart` 定义、
  由 `readObject` 捕获），`SessionPageShapeError` 删除。
- **同一规则只写一次，且是可单测的纯函数**：任务合并策略住 `core/job.dart`，
  `job.list` 快照与 `job` 帧推送共用它；`JobRow` 的必填键按生产者口径改 `require*`。
  **门槛**：删掉合并函数后至少一条用例变红（变异校验记在提交里）。
- **协议知识只住 `wire/`**：`session.page` / `session.refetch` 的"方法名 + 参数形状"
  搬进 `wire/rpc/session_page.dart` 的 `load*`，`core/` 只留 await 循环与排序；
  门禁改为扫 `app/lib` 全域（除 `wire/`）零 `call<`，不加白名单。
  **门槛**：脚本在 `core/` 里能找到的 `call<` 为 0；新增一个就会红。
- **一种形态一个入口**：`{key: [...]}` 只有一个 `readEnvelopeList`（含逐条计数），
  `record`/`refetch` 判别联合只在 `session_page.dart`；`modelSelection` 只有一份解析。
  **门槛**：六个面不再手写"取 Map → 取 key → 判 List"；`fields.dart` 的公开成员
  要么有调用点，要么删除。

## Alternatives considered

1. **只给 `page()` 补一个 `catch`（最小补丁）**。
   最强理由：改动 3 行、当天可上线，且完全恢复旧行为。
   被否：仍然保留两条失败通道——下一个 decoder 想"硬错"时还会再造一个异常类型，
   而调用方永远不知道要接什么。补 catch 治的是这一次，不是这一类。
2. **保留 `SessionPageShapeError`，在 `page()` 里显式捕获并折成 `failure`**。
   最强理由：异常能把"硬错"与"降级"分开，调用方无法忽略它（不接就崩）。
   被否：`WireBad` 已经能表达"整页读不出来"，再加异常等于同一件事两个表示；
   而且它把"哪些失败是致命的"分散到两个类型系统里。统一成 `WireReading` 后，
   测试也只剩一种断言方式。
3. **抽一个 `JobMergePolicy` 接口/类**。
   最强理由：策略可替换、可注入，未来若出现"可重跑任务"能换实现。
   被否：今天只有一条规则、没有第二种策略，接口只会增加一层间接；
   纯函数 `mergeJobRow(existing, incoming)` 已经可单测、可复用，且不会有人为它写工厂。
4. **门禁保留"两个目录"，把 `core/` 的 4 处写进例外清单**。
   最强理由：连接层的方法（subscribe/unsubscribe）本来就走 outbox，不是 RPC 请求面，
   用白名单能精确表达"这些是有意的"。
   被否：白名单会长（这次 4 条，下次 6 条），与已否的"方法名单表"同形；
   而 page/refetch 本来就可以搬进 `wire/`。搬完只剩 outbox 的 `method:` 字面量，
   它们不是 `call<`，门禁扫 `call<` 天然不覆盖——用机制分类，不用名单。
5. **六个信封各留一份，不抽公共入口**。
   最强理由：每个面的头注就贴在解码处，少一层间接，读起来不用跳文件。
   被否：这正是布局笔记 Problem 里写的病（"同一形态各写一遍，写错一处就是静默空值"）。
   信封的差异只有 key 名与逐条解码器，抽成一个入口不会丢掉出处注释。
6. **重开 codegen / JSON Schema**。
   最强理由：类型源唯一时，形状与解码不会漂。
   被否：与 2026-10-25 设计评审同因——连接器的 `MethodHandler` 回 `Promise<unknown>`，
   没有类型源；本轮的四条裁定也不需要它们。

## Consequences

- 收益：页级失败从"异常还是计数"二选一变成一条路；同类回归下一次会被
  `sync_client_test` 直接抓住，而不是等真机"翻页没反应"。
- 收益：任务状态只有一份合并规则，快照与推送共用；"永远转"这类问题
  从"靠人记得"变成"删掉函数就红"。
- 收益：门禁与它声称的不变量对齐；`core/` 再想加 RPC 调用会被当场拦下。
- 收益：信封/值解析收口后，加一个方法的成本仍是"一个 `read*` + 一个 `load*` + 一条金样"，
  但不再需要抄信封判断。
- 代价：六类修复会动到 6 个面文件与 4 个测试文件，其中 `job` 的必填化会让
  手写假行（`topbar_chips_test` 等）缺字段当场变红——这是有意的，假行必须照生产形状写。
- 代价：`page`/`refetch` 的调用搬进 `wire/` 后，`SyncClientImpl` 多一层委派；
  `page()` 仍是唯一知道"失败要留声"的地方，但方法名不再由它持有。
- 代价：`flatValues` 若被 `projections` 采用，非 Map 应答的计数从"调用方判"变成
  "入口计数一次"，`badCount` 的既有期望可能要改（逐条用例确认，不批量改）。

## 批次表

| 批 | 范围 | 验收（四条同时成立） | 状态 |
|---|---|---|---|
| 1 | 页级失败语义：删 `SessionPageShapeError`，`refetch` 缺 `seq` ⇒ `WireBad`；`page()` 把解码失败映射成 `failure`；`record` 解不出计数 | 先红后绿：`sync_client_test` 一条"坏页 ⇒ `failure` 且不抛"；回放用例改断言 `WireBad` + 计数 1；`dart analyze lib test` / `format` | ✅ |
| 2 | 任务合并策略：`core/job.dart` 的 `mergeJobRow` + `mergeJobSnapshot`；快照与推送共用 | 纯函数单测 4 条转移；`job_panel_test` 一条真赛跑（`completed` 后快照回 `running` 仍 `completed`）；回滚合并函数至少 1 红 | ✅（变异 5 红） |
| 3 | 必填口径：`job` 六键改 `require*`；`session.page` 改走 `readObject` 且 `hasMore` 必填 | 金样仍绿；缺任一必填键 ⇒ 整行为 `WireBad` + 计数 1 的新用例（循环覆盖六键）；手写假行补齐；analyze/format | ✅ |
| 4 | 信封与值解析收口：`readEnvelopeList` 一个入口、`modelSelection` 一份、删死代码、`projections` 走 `flatValues` | 六个面改用同一入口；`fields.dart` 无未用公开成员；回放用例全绿 | 待做 |
| 5 | 门禁范围与事实：`page`/`refetch` 的 `load*` 搬进 `wire/rpc/session_page.dart`；脚本扫 `app/lib`（除 `wire/`）；订正设计评审 `:267` | 脚本零 `call<`；在 `core/` 加一处 `call<` 会红（变异）；设计评审改成事实 | 待做 |
| 6 | 杂项：19 处回指、`permission.switch` 复用、`agentPresets` 断言、`_idsOf` 双计数、金样笔记的状态行 | 回指全部命中；`permission` 不再有第二份解码；回放覆盖 43/43；双计数用例 | 待做 |

## 代码入口回指

- 第 1 批：`app/lib/wire/rpc/session_page.dart`（失败只回 `WireReading`）、
  `app/lib/core/sync_client_impl.dart`（解码失败 ⇒ `failure`）
- 第 2/3 批：`app/lib/core/job.dart`（合并规则与 `JobRow` 必填口径）、
  `app/lib/wire/rpc/job.dart`（应答解码）
- 第 4 批：`app/lib/wire/fields.dart`（唯一字段读法 + 唯一信封入口）
- 第 5 批：`app/tools/verify-rpc-single-caller.mjs`（扫描范围）
