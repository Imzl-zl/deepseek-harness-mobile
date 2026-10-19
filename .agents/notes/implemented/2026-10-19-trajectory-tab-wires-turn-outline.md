# Agent Note: 轨迹页接 `turnOutline` 投影（此前恒显示"还没有轨迹"）

Status: implemented

## Problem

2026-10-19 摸到的"没看到的问题"之一：**轨迹页永远是空态**。

`ui/trajectory_page.dart` 的 `TrajectoryTab` 一直接收 `rows` / `entries`
两个参数（文件头还写着"没有示例数据兜底，2026-10-15 删了 `_sampleRows`"），
而 `chat_page.dart` 的 `_TrajectoryTab` **只传了 `onTapEntry`**：

```dart
class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab({required this.onTapEntry});
  @override
  Widget build(BuildContext context) => TrajectoryTab(onTapEntry: onTapEntry);
}
```

两个表恒为空 ⇒ `TrajectoryTab` 走空态分支 ⇒ 用户看到
"电脑侧跑完一轮后，这里会显示这一轮的时间轴与每一步的耗时"。
**契约 §5.7 里 `turnOutline` 一直都在**（`session.projections` 的已核实键），
手机也早就解析了同一次读取里的 `tokenUsage` / `sessionStats` /
`contextBreakdown` / `title` / `inbox`…… 只是从没把它接进来。

## Decision

### 1. `AppModel.turnOutline` —— 按 wire view 解析

DSH 的 `session-turn-outline/src/projection.ts:61-75`：

```ts
const turnOutlineEntriesSchema = z.array(z.object({
  turn: z.number().int().nonnegative(),
  seq: z.number().int().nonnegative().transform(SessionSeq),
  prompt: z.string().max(PROMPT_PREVIEW_LIMIT),
  response: z.string().max(RESPONSE_PREVIEW_LIMIT),
}).strict())
```

新建 `model/turn_outline.dart`（`TurnOutlineEntry`：`turn` / `seq` /
`prompt` / `response`，不可变；`promptLabel` / `responseLabel` 给空预览占位
`（没有预览）`）。解析时**逐项校验**：`turn` / `seq` 缺一个或不是 int 就跳过
这一项（与 `parseSubagentCatalog` 同一条纪律：认不出的项跳过，不抛、不猜）。

### 2. `_TrajectoryTab` 把投影喂成账本

一轮一行：`name` = `第 N 轮`、`prompt` = 用户那句预览、`summary` = 回复预览。
`took` **留空串** —— `turnOutline` 不带耗时字段（只有那四个），
空着比编一个数字诚实。

### 3. 账本行渲染提问（比回复弱一档）

`TraceEntry` 加 `prompt` 字段，渲染在 `summarymary` 之前、用 `labelCaption`
（更弱）—— 提问是"因"、回复是"果"，一屏里果比因重要。

## Alternatives considered（否掉的）

- **用消息流自己推轮次**（`MessageItem` 里找 `user/message` 边界）：DSH 已有
  投影，自己推一份就是第二真值源，而"轮次"的定义（`turn/start` 边界、
  重试轮怎么并）在 DSH 的 fold 里，推不出来。否。
- **甘特条也接上**（`sessionStats` 的 llmMs/toolMs 总量）：甘特要的是
  **每步**的起止，而 `sessionStats` 只有会话级总量（`llmMs` / `toolMs` /
  `ttftMs` / `decodeMs`）—— 拿总量画分段只能画两条 100% 宽的段，
  那是"看起来有数据"的假图。**留给需要逐步耗时的后续批次**。
- **给 `took` 填 `sessionStats` 的均值**：编的。否。

## Consequences

- 收益：轨迹页从"永远空态"变成"一轮一行，提问 + 回复预览都能看"
  （真机验证：6+ 轮，`第 1 轮` → `HANDOFF-NEXT-WORK.zh-CN.md 看这个提示词讨论`
  / `先说结论：**这份交接文档本身是可信的**……`）。
- 代价：`TraceEntry` 多一个 `prompt` 字段；账本行高一点（三行字）。
- 测试：`app/test/trajectory_outline_test.dart` 4 项 —— 解析（含跳过错形状项）/
  投影缺失 = 空表 / 空表显示空态 / 有轮次就一行一轮且提问回复都显示。
- 全量门禁：`flutter test 756` / `analyze 0` / `format 0`。
