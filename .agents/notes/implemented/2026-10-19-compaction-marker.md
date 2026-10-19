# Agent Note: 上下文压缩标记（compaction）——DSH Web 节点清单最后一个缺口

Status: implemented

## Problem

2026-10-19 顺着 DSH Web 的节点清单（`register-node-renderers.ts` 的 14 个 key）
逐个对照手机侧，`compaction` 是**最后一个**没接的。

DSH Web 在压缩落定时显示一条**检查点标记**（`CompactionItem`）：摘要 +
被替换掉的条目数 + 被压掉的 token 数。手机上没有 —— 于是"之前的对话被总结成
一段摘要替换掉了"这件事在手机侧**完全不可见**，而它影响后续**所有**轮次
（模型从此只看摘要，不看原文）。

**这不是假想的影响**：本会话自己就有一条（604975 token），
用户读到的这段 checkpoint 提示正是它产生的。

## 调查

### 真形状（真日志实测）

```json
{"type":"compaction/start","seq":4717,"data":{"compactionId":"324ce65d-…","turn":6}}
{"type":"compaction/summary","seq":4718,"data":{
   "compactionId":"324ce65d-…",
   "summary":[{"type":"text","text":"## Primary Request and Intent\n…"}],
   "shadowedSeqs":[8,9,10,…,4619,…],        // 142 个
   "shadowedTokenCount":604975,
   "provider":"…","model":"…","maxTokens":…,"usage":{…}}}
{"type":"compaction/end","seq":4720,"data":{"compactionId":"324ce65d-…","turn":6}}
```

压缩后紧跟一条 `user/message`（`source.kind` 是压缩类），内容就是摘要本身。

### DSH 的两条规则

`conversation-nodes/compaction.ts:34-48` 的 `match`：
- 三条事件（start / summary / end）共用 `compactionId`；
- **带 `sourceCommandId` 的一律返回 null**（`:42`）—— 手动 `/compact`
  归 `manual-compaction` 节点，由命令卡呈现。

`command.ts:101-121` 的 `compactSummary`：
- `summary` = `data.summary` 里 `type === 'text'` 的块**拼接**；
- `shadowedItemCount` = `shadowedSeqs.length`，但**要求每个元素都是安全非负
  整数**，否则整项作 null；
- `shadowedTokenCount` 同样要求安全非负整数。

## Decision

### 1. `core/items.dart` 加第三种身份键

`compaction/start|summary|end` → `x:$compactionId`（缺字段抛错）。
这是继 `toolCallId` / `commandId` / `retryId` 之后的**第五种**配对键。

### 2. `model/chat_item.dart` 加 `CompactionItem`

`summary` / `shadowedItemCount?` / `shadowedTokenCount?` + `stats` getter。
**两个计数可空**（形状不可信就不显示），`stats` 只列有的项 ——
不摆"替换 0 条"这种噪声。

### 3. 投影：三条事件是同一条被更新三次

- `summary` 带内容；`start` / `end` 只是边界。
- **`start` / `end` 而前面没有 summary → skip**（无内容可显示）。
- **`start` / `end` 在 summary 之后 → 继承**（`previous` 是 `CompactionItem`）。
- **带 `sourceCommandId` → skip**（手动 `/compact` 走命令卡）。
- 两个计数照 DSH 的严判据逐项校验。

### 4. `ui/chat_turns.dart` 加 `CompactionRow`

一行（`compact` 图标 + 标题 + 等宽统计），摘要**默认收起**（它可能上万字符，
展开会把对话流冲掉），点开可见。底色用助手色的极淡底 —— 它是
"模型看到的世界在这里换了"，不是错误、也不是工具。
摘要正文**不用 Markdown**：它本身就是给模型看的压缩稿，原样等宽显示更接近真相。

## Alternatives considered（否掉的）

- **只在设置页显示"发生过压缩"**：压缩是**会话流里的一个事件**，
  用户在翻历史时会经过它，那时看见标记才理解"为什么这里之后内容变了"。
- **摘要用 Markdown 渲染**：压缩稿里大量 `##` / `**` 是给模型的结构提示，
  渲染成富文本会让它看起来像助手说的话。等宽原样更诚实。
- **自动展开摘要**：604975 token 的压缩摘要动辄上万字符，自动展开会
  把对话流冲掉。默认收起 + 可点开。

## Consequences

- 收益：DSH Web 节点清单的 14 个 key **全部有对应呈现**（其中 `unknown`
  是 `OtherItem`、`turn-tail` / `assistant-actions` 是桌面专属操作不计）。
- 代价：`ChatItem` 多一个子类型、`items.dart` 多一种配对键。
- 测试：`compaction_item_test.dart` 10 项（itemId 三条同 id / 缺字段抛错 /
  摘要拼接 / start-end 无内容 skip / end 继承 / **严判据两类都测** /
  手动 compact 跳过 / 非 text 块跳过 / 三段贯通），并做了**变异验证**
  （去掉 `seq < 0` 校验后测试变红 —— 第一版只测了字符串，变异没抓到，
  补了负数用例后才真能守）。
- 全量门禁：`flutter test 800` / `analyze 0` / `format 0` /
  `boundary 281` / `icons 100`。

## 未验证的部分（说清楚）

**真机上没看到压缩标记**：adb 反复被 ROM 行为打断。投影与渲染都有测试
（含变异验证），但端到端要用户在**发生过压缩的会话**里看
（本会话 `session-1f80f156` 就有一条）。
