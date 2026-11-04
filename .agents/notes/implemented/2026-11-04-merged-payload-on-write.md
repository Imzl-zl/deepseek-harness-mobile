# Agent Note: 同一个 itemId 的载荷合并写，而不是只留最后一条事件

Status: implemented

## Problem

2026-11-04 真机：重启 App 之后，**所有工具行都显示成「工具」**，重试行显示成
「重试 1/0」（连失败原因都没有，展开也没东西可看）。同一条重试行在重启前是
「重试 1/5 Your requests to gpt-6.1-sol…」。

根因在**落盘**，不在投影：

- 本地库每个 `itemId` 只存**最后一条事件的 `data`**（`data/store.dart` 的
  `StoreItemPersister`）；
- 而 DSH 的事件是**分两条到达、共用同一个 `itemId`** 的：`tool/call`（带
  `name` / `arguments`）→ `tool/result`（只带 `message`）、`llm/retry`（带
  `maxRetries` / `failure`）→ `llm/retry-started`（只带 `retry`）；
- 投影靠内存里的 `previous` 合并两半（`projection.dart` 的 `tool/result` /
  `llm/retry-started` 分支）。冷启动没有 `previous`，于是名字与原因就没了。

真机库的旁证：`items` 表 **200 条 `tool/result`、0 条 `tool/call`** —— 调用那条被结果
覆盖掉了。

## Decision

`StoreItemPersister` 写盘前先读这一批 `itemId` 现在的载荷（新增
`ItemStore.payloadsOf`），写入的是**旧 ∪ 新**（新键覆盖旧键）。

准入门槛：

1. **方向只加不减**：旧键保留、新键覆盖。投影只读它认识的键，多出来的键不会被误读。
2. **合并只在"对象载荷"上做**：不是对象 / 旧载荷读不出来，就退化成新载荷（不拿一个
   坏东西挡住这次写入）。
3. **投影要能读回合并后的字段**：`tool/result` 的 `name` / `arguments`、
   `llm/retry-started` 的 `maxRetries` / `failure` / `delayMs` 都有 `previous == null`
   时的兜底 —— 字段名只在 `wire/events.dart` 断言（`mergedToolCallOf`），
   机械规则 `wire-field-single-reader` 会拦"在投影层另解释一遍线上形状"。

## Alternatives considered

1. 盘上直接存**投影后的界面条目**（而不是事件载荷）
   - 最强的理由：一次投影，读回来就是成品，不会有"两半"的问题。
   - 为何被否：`StoredItem` 的既定纪律是"存事件、投影在读取时做"——投影规则改了，
     盘上的历史仍然能按新规则重放。存成品等于把投影版本钉死在落盘那一刻。
2. 调用与结果**各存一行**（不共 itemId）
   - 最强的理由：两条事件本来就各是完整事实，不需要合并。
   - 为何被否：`itemId` 是契约 §5.2 的身份（`toolCallId` 配对），改它等于改协议；
     而且界面上会变成两张卡（DSH 是一张）。
3. 冷启动时把窗口**从电脑侧重放一遍**，用真事件重建
   - 最强的理由：不依赖本地载荷，历史一定完整。
   - 为何被否（本次）：它修不了"已经落盘的历史"之外的东西，却要每次冷启动多搬一整窗
     （几百 KB）；而合并写是**一次修好、以后都不丢**。重放可以作为"历史修复"的单独动作，
     见下面的代价。
4. 什么都不改，只在投影里从 `data` 兜底
   - 最强的理由：改动最小。
   - 为何被否：`data` 里根本没有那些字段（它们被覆盖掉了），兜底读不到任何东西。

## Consequences

- 收益：**新收到的事件**不再丢字段 —— 工具行有名字、重试行有原因与上限，冷启动也成立。
- 代价：写盘前多一次按批次的读（`payloadsOf`，一条 `IN (...)` 的 SELECT）；
  载荷比单条事件大一点（多几个键）。
- **仍欠一条：已经落盘的历史修不回来。** 那些行在本地只剩结果那一半，只有电脑侧
  还有原始事件。要修历史得单独做一次"重放这一窗"（`session.page` → 重新走合并写），
  本次没做 —— 它是一次性的数据修复动作，和写入路径是两件事。
