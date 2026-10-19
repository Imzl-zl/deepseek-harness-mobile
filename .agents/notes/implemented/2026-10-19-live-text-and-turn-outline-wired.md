# Agent Note: 消息流显示流式文本 + 轨迹页接 turnOutline（两个"看不到的输出"）

Status: implemented

## Problem

用户 2026-10-19 原话："会话渲染只有思考，工具调用，**没有输出**，运行命令啥的
（这只是我看到的还不说没看到的问题有多少）"。

2026-10-19 早前已用**真事件 fixture** 修掉三处投影缺陷（工具名被 `tool/result`
覆盖 / 参数行是 JSON 键名 / 系统消息内联巨墙），并证实**最终**消息渲染是对的。
这一轮再摸，发现两个"看不到的输出"是**接线**问题，不是投影问题：

### 1. 流式文本从不显示（"没有输出"的实时版）

`AppModel.liveText` 有 getter，`core/sync_client_impl.dart:715` 也一直在填它
（`live` 帧 → `LiveAccumulator` → `SessionDelta.liveText`），
而 **UI 从不读它**（全仓 grep `liveText` 在 `ui/` 下零命中）。

症状：用户发一句话后，要盯着"什么都没有"等到**整步跑完**、持久
`assistant/message` 落下来才看到内容。DSH Web 在流式期间就显示正在增长的正文
（`ui-chat/src/client/chat/AssistantNodeView.tsx`）。

### 2. 轨迹页永远显示"还没有轨迹"

`TrajectoryTab` 一直接收 `rows` / `entries`，而 `chat_page.dart` 的
`_TrajectoryTab` **只传了 `onTapEntry`** —— 两个表恒为空，永远走空态分支。
契约 §5.7 里 `turnOutline` 一直都在，手机也早就解析了同一次读取里的
`tokenUsage` / `sessionStats` / `contextBreakdown` / `title` / `inbox`，
只是从没把它接进来。

## Decision

### 1. 流式文本 = 虚拟尾条目

`_ConversationFlow` 新增 `liveText` 参数，`ListView` 的 `itemCount` 加一，
那一格在 `reverse: true` 的 **index 0**（最新一端），渲染 `_LiveTurn`：

- 有文本 ⇒ `DshMarkdown(text)`（与持久消息同一套渲染）；
- 空串 ⇒ "正在生成…"占位（这一步开始了但还没有文本，可能在等工具结果）——
  说"正在生成"比一片白诚实；
- `null` ⇒ 不多格。

它是**虚拟条目**：没有稳定 itemId（不进 store、不当 `ChatItem`），
持久 `assistant/message` 到达后 `AppModel` 不再给值，那条消息**整体替换**它
（`app-channel-client.md` §2.2：以持久为准）。

`_step`（上一条/下一条）对 index 0 是空操作——流式条目没有 key，
`ensureVisible` 拿不到 element，不猜一个位置。

### 2. 轨迹页接 `turnOutline`

新建 `model/turn_outline.dart`（`TurnOutlineEntry`：`turn` / `seq` /
`prompt` / `response`，不可变；空预览给占位 `（没有预览）`）。
`AppModel.turnOutline` 按 DSH 的 `turnOutlineEntriesSchema`
（`session-turn-outline/src/projection.ts:61-75`）逐项校验：
`turn` / `seq` 缺一个或不是 int 就跳过这一项（不抛、不猜）。

`_TrajectoryTab` 一轮一行：`name` = `第 N 轮`、`prompt` = 用户那句、
`summary` = 回复预览。`took` **留空串** —— `turnOutline` 不带耗时字段
（只有那四个），空着比编一个数字诚实。

`TraceEntry` 加 `prompt` 字段，渲染在 `summary` 之前、用 `labelCaption`
（更弱）—— 提问是"因"、回复是"果"，一屏里果比因重要。

## Alternatives considered（否掉的）

- **甘特条也接上**（用 `sessionStats` 的 `llmMs` / `toolMs`）：甘特要的是
  **每步**起止，而 `sessionStats` 只有会话级总量 —— 拿总量画分段只能画两条
  100% 宽的段，那是"看起来有数据"的假图。留给需要逐步耗时的后续批次。
- **从消息流自己推轮次**：DSH 已有投影，自己推一份就是第二真值源，而"轮次"
  的定义（`turn/start` 边界、重试轮怎么并）在 DSH 的 fold 里，推不出来。
- **流式文本也进 store**：没有稳定 itemId，而 store 是 upsert-only 的
  （契约 §5.2）—— 进 store 会让"同一条消息有两个 id"。

## Consequences

- 收益：生成过程中能看到正文在长；轨迹页从"永远空态"变成"一轮一行，
  提问 + 回复预览都能看"（真机验证：6+ 轮）。
- 代价：`_ConversationFlow` 多一个参数 + 一个私有 widget；`TraceEntry`
  多一个 `prompt` 字段；账本行高一点（三行字）。
- 测试：`live_text_turn_test.dart` 4 项（`AssistantTurn` 同款头部 /
  空文本占位 / **live 帧 → getter 有值** / null 与空串是两件事）；
  `trajectory_outline_test.dart` 4 项（解析含跳过错形状项 / 投影缺失 = 空表 /
  空表显示空态 / 有轮次就一行一轮）。
- 全量门禁：`flutter test 760` / `analyze 0` / `format 0`。

## 未验证的部分（说清楚）

**真机上没看到流式文本在长** —— `adb input text` 往 MIUI 输入法注入不稳定
（tools.md 记过），反复把模型选择器点开、把 App 退回桌面，七次都没发送成功。
赋值路径（`live` 帧 → `AppModel.liveText`）有单测钉住，渲染路径
（`_LiveTurn`）有 `AssistantTurn` 同款判据，但**两端接起来的样子要用户
自己发一句话看**。下次真机验收时补这一条。
