# 事件字段只有一个读者：`core/event_wire.dart`

- 日期：2026-10-25
- 状态：已落地
- 相关：`implemented/2026-10-24-plan-review-card-from-request.md`（事故现场）、
  `tools.md`（「事件到了没」的二分配方）、`memory.md` 教训第九条

## Problem

2026-10-25 真机：计划审查卡在手机上一次都没出现。查下来不是传输 —— 手机库里
`t:call_16f5bd…` 那条 `tool/call` 好好地躺着，`payload_json.arguments` 的类型是 **`str`**。
坏在同一个字段两种读法：

| 文件 | 它以为 `arguments` 是什么 |
|---|---|
| `app/lib/core/items.dart` | JSON 字符串（`toolArgumentsSummary(name, arguments)` 的入参就是 `String`） |
| `app/lib/data/projection.dart` | **对象**（`fieldOf(fieldOf(data,'arguments'),'plan')`） |

`fieldOf` 对非 `Map` 恒回 `null` ⇒ `plan == null` ⇒ `return null` ⇒ **不开卡、不报错**。
而"这条事件与交互无关"在同一个函数里也返回 `null` —— 两种完全不同的结论共用一个返回值，
于是整块功能静默消失，日志一片干净。

单测没拦住的原因是同一个病的第二个面：`plan_review_test.dart` 的构造器喂的是
`'arguments': {'plan': plan}`（**对象**），线上从来没出现过这个形状 ——
用例把实现里的错误假设一起写死了，两边一起绿。

这类病会重复：只要"字段叫什么、是什么类型"散在各调用点，就总有一处会猜错，
而猜错的默认表现是空值。

## Decision

**一条不变量 + 三个机制。**

不变量：**线上事件载荷的字段名与类型只在 `app/lib/core/event_wire.dart` 里断言一次；
读不出来必须成为一次"响"，而不是 `null`。**

机制：

1. **单一解码层** `core/event_wire.dart`
   - 只收我们真正消费的事件（`tool/call`、`tool/result`、`approval/asked|decided`、
     `user/message` 的 `user-question-reply`、`command/run|done`）。不建全量 schema ——
     那会变成第二个真值来源。
   - 三态结果 `WireReading<T>`：`WireOk` / `WireSkip`（不是我要的事件）/ `WireBad`（形状错）。
     **没有"可空"这一档**：`null` 已经被"与交互无关"占用。
   - `parseArguments` 是这个字段唯一的解释口；`tool/call` 的 `name` **可空**——
     身份是 `callId`，名字是展示（缺了有 `kUnknownToolName` 兜底），把缺名字判成形状错
     会把一条身份完好的事件整条丢掉（被一条旧用例当场拦下）。
2. **出声有唯一出口** `WireDiagnostics`：`WireBad` 经 `valueOrReport` 统一计数；
   `items.dart` 那种"缺身份直接抛"的地方用 `valueOrNull`（抛比打印更响）。打印由装配点
   （`main.dart`，仅 `kDebugMode`）接 `debugPrint` —— 这一层是**纯 Dart**，
   `items.dart` 至今零 Flutter 依赖那件事不能破。
3. **两道闸**
   - 门禁规则 `wire-field-single-reader`（`app/tools/verify-platform-boundary.mjs`）：
     `'arguments'` / `'toolCallId'` 两个字面量只许出现在 `event_wire.dart`。
     注释里提到不算（`firstCodeUse` 先剥注释）。
   - 回放用例 `test/event_wire_replay_test.dart`：`fixtures/real-session-events.json` 里
     **每一条真机事件都必须解得出**（`WireBad` 数 0），且 fixture 不许缩水
     （六个关键键缺一不可，否则会成为"空集上全绿"）。
     新增两条真机事件：`planCall`（2026-10-25 会话日志 `seq:87`）与 `questionCall`（`seq:129`），
     与手机库 `items.payload_json` 逐字对照过。

## Alternatives considered

1. **只修那一行（按字符串解）**
   - 最强的理由：改动一行、零风险、当天就能上真机。
   - 为何被否：这就是 2026-10-25 之前的状态 —— 同一个字段仍然有两处解释，下一个人照着
     隔壁那段抄一遍就复发。**patch 修的是这一处，不修"会再有一处"。**
2. **在流入口做全量 schema 校验（每个事件类型一张表）**
   - 最强的理由：形状错误在**进入系统之前**就被拦住，消费端可以完全不设防。
   - 为何被否：DSH 的事件类型有几十种，我们只消费其中七种；为没消费的类型维护 schema
     等于抄第二份真值（DSH 升级就得跟着改），而且**我们并不需要**那些字段。
     收窄到"消费什么断言什么"是同一件事的更小形态。
3. **给 `fieldOf` 加类型参数（`fieldOf<String>(data,'name')`）**
   - 最强的理由：不用新文件，只改调用点。
   - 为何被否：泛型取字段只能表达"我想要什么"，表达不了"线上是什么"——
     `fieldOf<Map>(data,'arguments')` 照样编译过、照样得 `null`。这次的病根是
     **没有人负责说出线上形状**，不是取字段的方式不够花。
4. **codegen（从 DSH 的类型生成 Dart 模型）**
   - 最强的理由：形状永远跟宿主一致，最彻底。
   - 为何被否：跨仓库生成链（DSH 是只读参考源码，不是我们的依赖）会把构建变成两段，
     而真正需要的只有七个事件的十几个字段。代价远大于收益；将来事件面变大再议。

## Consequences

- 收益：同一个字段只有一处解释；形状漂移**当天**在回放用例与门禁上红，不用等真机；
  `null` 的含义重新变干净（"这条不是我要的"）。
- 代价：多一层类型（七个 wire 类 + 三态结果），读事件的地方要先 `valueOrReport`；
  新增"消费一类事件"要同时在 `event_wire.dart` 与 fixture 里各加一处（这是有意的摩擦）。
- 代价：`WireDiagnostics.badCount` 是**进程级**计数，没有按会话分桶 —— 排错面板要用它时
  再决定要不要加维度（现在只有回放用例与测试读它）。
- 代价：门禁项数从 391 涨到 **507**（多一条规则 × 111 个文件 + 3 条自检 + 1 个新文件），
  以后每次动 `app/lib/` 的输出数字都会变 —— 数字的唯一出处仍是 `tools.md`。
- **未做**：把 `session.projections`（`modelSelection` / `permissions` / …）也收进同一层。
  它们同样是线上形状，但不在这次事故的路径上，且几十个字段的迁移会淹没"一个字段一个读者"
  这条主线。下一步该做，但不是同一批。

## 判据

- `flutter test` **1235 → 1241**：新增 `test/event_wire_replay_test.dart` 6 条 ——
  真机事件全部解得出（`badCount == 0`）、fixture 不缩水、计划事件开出 `plan` 卡
  （正文取事件自己的 `plan`）、提问事件三选项齐全且读 `multi_select`、坏 JSON 只回 `null`
  不入计数、缺身份出声并计数。
- **变异校验**：`parseArguments` 改成恒 `null` ⇒ 恰好 3 条红（计划卡投影 + 回放的计划与提问）；
  门禁规则用临时探针文件验收 ⇒ 恰好 1 条红（`wire-field-single-reader` 命中 `'arguments'`）。
- `node app/tools/verify-platform-boundary.mjs` **391 → 507**（规则自检 22 → 25，文件 110 → 111）。
- `dart analyze --fatal-infos` 0、`dart format` 0（跑 `lib test integration_test`）。

## 代码入口回指

- `app/lib/core/event_wire.dart`（解码层本体；头注写了三条不变量与形状证据）
- `app/lib/data/projection.dart`（`tool/call` 与 `interactionSignalOf` 走解码层）
- `app/lib/core/items.dart`（`itemIdOf` 的身份字段走解码层，缺身份仍抛）
- `app/lib/main.dart`（装配点：`kDebugMode` 下把 `WireDiagnostics.sink` 接到 `debugPrint`）
- `app/tools/verify-platform-boundary.mjs`（`wire-field-single-reader`）
- `app/test/event_wire_replay_test.dart` + `app/test/fixtures/real-session-events.json`
