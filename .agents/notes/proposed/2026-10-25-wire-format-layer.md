# 线上格式收成一层：`app/lib/wire/`

- 日期：2026-10-25
- 状态：待评审（第 1 步已落地：内核搬家，见文末「已落地 / 待搬」）
- 相关：`implemented/2026-10-25-event-wire-single-decoder.md`（事件面已经收口）、
  `implemented/2026-10-24-plan-review-card-from-request.md`（事故现场）

## Problem

"线上格式"在这套代码里有两个面，**都**在按调用点各猜各的：

| 面 | 谁给形状 | 现在的读法 | 裸 Map 读取点 |
|---|---|---|---|
| **会话事件**（`ev` 帧的 `type`+`data`） | DSH 的会话格式（`session.v4.jsonl`） | 事件面已收进 `core/event_wire.dart` | 0（已搬） |
| **RPC 应答**（28 个方法） | **连接器**（`connector/src/handlers.ts` + 契约 §5.7） | `result is Map ? result['x'] : null` 就地取 | **~40 处**（`app_model.dart` 为主） |
| **投影值**（`session.projections.values`） | DSH 的投影（连接器裸过线） | 同上一列：`fieldOf` / `is Map` 就地取 | `projection.dart` 内约 20 处 |

实测（2026-10-25 扫描 `app/lib`）：`fieldOf(` / `stringField(` / `nonEmptyString(` /
`jsonDecode(` / `as Map` 合计 **103 处，17 个文件**：

```
projection.dart 64   items.dart 11   sync_client_impl.dart 7   app_model.dart 6
其余（frame / pairing / store / tool_view / plugins / usage …）零散 15
```

病与计划卡那次**逐字相同**：`null` 同时表示"没有这个字段"与"我读不懂"，
于是形状一变就是**静默的空值**；而用例喂的往往是手捏的形状，两边一起绿。

已经付过两次学费：`repo.info.commands`（`string[]` → `{name,description?}[]`，手机两种都收）、
`session.projections`（`null` / `{kind,asOfSeq,values}` 两态，取错一层就整块空、单测全绿）。

## Decision

**一条不变量，四个规则。**

不变量：**线上载荷的字段名与类型，只在 `app/lib/wire/` 里断言；读不出来必须"响"，
不许变成 `null`。** 消费方（`data/` `model/` `ui/`）拿到的永远是解好的值。

1. **一层两个面**：
   ```
   app/lib/wire/
     reading.dart        内核：WireReading<T> = Ok | Skip | Bad；WireDiagnostics 计数
     events.dart         会话事件（从 core/event_wire.dart 搬来，形状只此一处）
     rpc/<family>.dart   一个方法族一个文件：session.dart / repo.dart / files.dart /
                         plugins.dart / refs.dart / usage.dart / settings.dart /
                         jobs.dart / command.dart / interaction.dart
   ```
   每个 decoder 的头注写**形状出处**（`connector/src/handlers.ts:行号` 或契约 §5.7 的行），
   **不许写"看起来是"** —— 这就是"不猜"的机械形态：审的人只需要核对那一行。
2. **形状只有一个出处，测试从真机抓**：每个 decoder 配一条回放样本，
   来源是**真机/真实例抓到的原始 JSON**（不是手写的"差不多"）。抓法见下「取证」。
3. **两道门禁**（现有机制的延伸）：
   - `wire-field-single-reader`：`'arguments'` / `'toolCallId'` 之外，再按面禁
     "对 `Object?` 做字符串下标" —— 即 `app/lib/` 里除 `wire/` 与 `core/frame.dart` 外，
     不许出现 `is Map ? … ['x']` 与 `fieldOf(` / `stringField(`。
   - 回放用例：每个 decoder 的样本都必须 `badCount == 0`，且样本文件不许缩水
     （键集合断言，缺一条就红）。
4. **出声有唯一出口**：`WireDiagnostics.badCount` + 装配点打印（debug-only）。
   与事件面共用同一个计数 —— "这个 App 有没有读到过不懂的形状"是一个数，不是两个。

## 取证：真机/真实例抓原始应答（0 个模型请求）

RPC 应答不落盘（`items` 只存事件），所以要抓一次：

- 加一个 **debug-only 的取证口**（`platform/` 里，`kDebugMode` 守）：每个 `client.call`
  的应答按 `method` 追加到 `wire-capture.jsonl`（`dart:io`，仅桌面/调试）。
- `flutter run -d windows` 连隔离实例，点一遍：会话列表 → 打开会话 → 投影 → 文件页 →
  插件页 → 用量页 → `@` 候选。**一次拿齐 ~20 个方法的真样本**（`AGENTS.md` 已记：
  桌面调试不需要模拟器与真机）。
- 抓完把样本按方法切进 `app/test/fixtures/wire/<method>.json`，取证口删掉（一次性仪器，
  与 `D:\tmp\dsh-e2e` 那些脚本同一性质）。

## Slicing（每个方法族一个提交，各自一条回放）

| 顺序 | 面 | 方法 | 为什么排这个位置 |
|---|---|---|---|
| 1 | 内核 | — | 搬家 + 门禁（已落地） |
| 2 | 会话身份面 | `session.list` / `session.page` | 已经出过两次事（父级、运行态）；行里有 12+ 字段 |
| 3 | 投影 | `session.projections`（15 个键） | `null` / `{values}` 两态坑过一次；统计条/权限/用量都吃它 |
| 4 | 能力面 | `repo.info` | commands 两种形状已经踩过；caps 决定四个页面出不出现 |
| 5 | 文件与引用 | `file.list` / `file.read` / `refs.files` / `refs.sessions` | 面板与文件页都吃；行形状窄、好搬 |
| 6 | 插件 | `plugin.list` / `listBundles` / `install*` | 宿主字段名原样过线，最容易猜错 |
| 7 | 用量 / 设置 / 任务 / 命令 | `usage.summary` / `settings.*` / `job.*` / `command.execute` | 低频，收尾 |

搬完一个族，就把它在 `app_model.dart` 的 `is Map ? …` 与 `model/*.dart` 的 `as Map` 删掉 ——
**删旧的读法**是这一步的验收，不然就是"又加了一层"。

## Alternatives considered

1. **从连接器的 TS 类型生成 Dart 模型（codegen）**
   - 最强的理由：形状永远与生产者一致，是这件事的终点形态。
   - 为何不当第一刀：连接器与 App 是两个独立工程（`connector/` 不是 DSH workspace 成员，
     与本仓无构建关联）；生成链要先做成一段构建，而真正需要的是 28 个方法里约 120 个字段。
     生成器本身也要维护，收益要等"字段上百"才回本。**留作将来**：真到那天，
     `wire/rpc/*.dart` 就是生成目标，手写部分只剩语义映射。
2. **在帧入口做运行时 schema 校验（每个方法一张 JSON Schema）**
   - 最强的理由：形状错误在进系统前就被拦，消费端完全不设防。
   - 为何被否：Schema 与 decoder 是两份要同步的真值；而且我们并不需要通用校验 ——
     需要的是"这 120 个字段各是什么类型"，那正是 decoder 干的事。真要做校验，
     也应该由 decoder 兼任（`Bad` 就是校验失败），不要再引第三份描述。
3. **给每个模型类加 `fromJson`，就地解析**
   - 最强的理由：最少的新概念，Dart 程序员最熟。
   - 为何被否：`fromJson` 立刻分叉 —— 有的抛、有的回 null、有的给默认值（今天就三种都有）。
     不变量要求**一个统一的失败语义**（`Bad` + 计数），那属于一层，不属于每个类。
4. **维持现状，只把出事那几处补上**
   - 最强的理由：零结构改动。
   - 为何被否：这就是过去三轮的状态 —— 每次都是"事后补一处"，而每次的形态都是静默空值。
     103 处里已经出过 3 次事，按这个比例还有几十次。

## Consequences

- 收益：形状知识从 17 个文件收到一个目录；失败语义只有一个（且可计数）；
  新方法的形状出处必须写成 `connector/...:行号`，评审能核；用例用真样本，不再自证。
- 代价：28 个方法要分 7 批搬，每批都要抓样本 + 改调用点 + 删旧读法；
  `app_model.dart` 会瘦一大圈（那是好事，但那是个大 diff）。
- 代价：多一层间接（`wire/rpc/x.dart` → 模型类）。为了不让它变成"多一层没用的壳"，
  decoder 直接产出**已有的模型类**（`SessionRow` / `PluginBundle` / `FilePage` …），
  不另造一套 DTO。
- 风险：抓样本那一步要跑一次桌面 App（**0 个模型请求**，但要占用几分钟）；
  抓不到的方法（例如 `plugin.install` 的进度帧）就先用连接器源码的形状 + 回放单测兜着，
  并在 decoder 头注注明"样本待补"。

## 已落地 / 待搬

- **已落地（本次）**：`wire/reading.dart`（内核从 `core/event_wire.dart` 搬出）+
  `wire/events.dart`（事件 decoder 原样搬家）+ 门禁路径更新。行为零变化，
  判据：flutter 1241 / boundary 507 / analyze 0 / format 0 全绿。
- **待搬**：上表第 2–7 行。每行一个提交，各自带真样本。
