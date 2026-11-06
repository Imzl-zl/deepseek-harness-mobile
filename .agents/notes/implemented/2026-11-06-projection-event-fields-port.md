# 投影的"事件载荷读者"独立成端口：第一族（工具 / 审批 / 提问）

- 日期：2026-11-06
- 状态：implemented（**第 1 族 / 共 3 族**；收尾时加门禁，见末节）
- 前情：`data → wire` 四批落地后 `app/lib` 只剩 `data/projection.dart` 一条 wire
  import（`implemented/2026-11-06-p1b-batch4-read-write-ports.md`）。

## Problem

那条 import 只是冰山。`data/projection.dart` 是"事件语义的唯一归宿"（哪条事件变成
界面上什么），但它同时**在读线上字段**：

- 6 个读者从 `wire/events.dart` 直接 import（`readToolCall` / `readToolResult` /
  `readApprovalAsked` / `readApprovalDecided` / `readQuestionReply` / `mergedToolCallOf`）；
- 另外 **42 处 `fieldOf(data, '…')`** 直接读线上字段名，覆盖约 20 种事件。

两件事的变更原因不同：DSH 改字段名只该动 `wire/`，我们改界面表现只该动 `data/`。
混在一起时，改字段名要进投影，改投影又要看懂线上形状。**门禁也看不见** ——
`verify-*` 只数 import，所以"1 条 import"底下藏着 42 处字段名。

## 被否掉的方案（先说，免得后人再走一遍）

**在解码边界产出 typed 事件**（`SessionEvent.body` + 每种事件一个 sealed 子类型）：
形状最漂亮，但代价全落在不该付出的地方 ——

- `SessionEvent` 加必填字段 ⇒ **60+ 个构造点**（多数在测试）；
- 动**收帧热路径**（每条事件都要解），而落盘存的是原始 `data`，冷启动还得再解一次；
- 换来的"编译器穷举"在"DSH 上游会加新事件类型"这个现实下**本来就要留 default 分支**，
  等于没换到东西（`projectEvent` 现在就有 `OtherItem` 兜底）。

## 这一版（第 1 族）

```text
core/event_fields.dart      EventFields（6 个方法，返回可空）+ 5 个载荷值类型
wire/event_fields.dart      WireEventFields：调 wire 读者 → valueOrReport 计数 → 值或 null
```

- **读不出就是 `null`**：计数与出声留在 `wire/`（`valueOrReport`）。因此 `data/` 不再
  需要三态内核（`WireReading` / `WireBad`），那条 import 才真的能删掉。
- **值类型搬进 core**（`ToolCallPayload` 等 5 个）：它们要穿过端口交给 `data/`，类型跟着
  端口走，`wire/events.dart` 里原来那 5 个 `*Wire` 类**删掉**（不 typedef、不留别名）——
  留一份同样的字段表就是两处真值。`command/*` 的载荷没有手机侧消费者，留在 wire。
- **只放真实消费者的方法**：`readCommandRun` / `readCommandDone` 只有 `EventIdReaders`
  与回放用例在用，**不进端口**（端口上多一个没人调的方法就是一处要维护的空转面）。
- **注入**：`HostRpcHolder` 加第三个 getter `eventFields`（纯解码、不碰连接，所以
  `WireHostRpc` 直接给 `const WireEventFields()`）；`projectEvent` /
  `interactionSignalOf` 收 `required EventFields fields`。装配点、`SyncClientDeps`、
  5 处装配行**一行没改**。
- **测试路径不变**：`test/projection_fixture.dart` 传的是**生产那份** `WireEventFields`，
  夹具仍是原始协议 JSON；它同时新增 `interactionSignalOf` 的转发版，19 个用例调用点
  一个字符没改（沿用 P1 给 `projectEvent` 建转发版的同一手法）。

## 验证

- `dart analyze --fatal-infos lib test` / `integration_test` → 各 0。
- `flutter test` → **1759** 全过。
- `verify-platform-boundary.mjs` → **804** 项全过（185 → **187** 个文件）。
- `verify-rpc-single-caller.mjs` → PASS；`dart format --set-exit-if-changed` → 0。
- `git grep -l "wire/" -- app/lib`（`wire/` 之外）→ **0 个文件**：`data/projection.dart`
  的最后一条 wire import 也关掉了。
- `data/` 里 `fieldOf(` → **42 → 33**（剩下的属第 2、3 族）。
- **变异校验**：`WireEventFields.toolCall` 改成恒 `null` ⇒
  `plan_review_test` + `message_rendering_test` + `event_wire_replay_test` **3 条红**；
  还原后 20 条全绿。

## 边界（这一版覆盖到哪里）

- 本族只覆盖工具 / 审批 / 提问这 6 个读者。`data/` 里仍有 **33 处** `fieldOf(`：
  消息与内容块、压缩三段、重试、`turn/end` 的 reason 嵌套、`workspace/changes`、
  `file` / `image`、`meta.diffs` —— 它们仍按原样读线上字段名。
- 因此**门禁还没加**：`data/` 禁 `fieldOf(` 这条要等上面那些搬完才成立。
  这一版能保证的只是一件事：`app/lib` 里 `wire/` 之外**零 import**。
