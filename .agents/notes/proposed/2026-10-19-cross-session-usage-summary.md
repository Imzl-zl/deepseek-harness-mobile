# Agent Note: 跨会话用量汇总 —— 连接器加 `usage.summary` 方法（方案，待实施）

Status: proposed

## Problem

用户原话（2026-10-19）：

> "还有用量统计这个我们也可以加，这个 dsh 源码有但是是单会话的，应该可以再插件加
> 这个能力插件汇总统计传输应该没问题，dsh 原生都有的"

已核实的现状（都查了 DSH 源码，不是猜的）：

- DSH 的 `tokenUsage` 投影是**单会话**的：`packages/llm/token-meter/src/usage-projection.ts:56-63`
  的 state 是 `{totals, last:{turn, step, buckets}}` —— 一个会话一份，没有跨会话汇总。
- `sessionStats` 投影（`packages/session/session-stats/src/projection.ts`）同样按会话
  （turns / steps / wall-time），也没有汇总。
- 所以"汇总"在 DSH 侧**不存在现成接口**，必须在连接器（我们的插件）里做。

## Decision（方案）

### 1. 新方法 `usage.summary`（手机→电脑，只读）

挂在与 `session.list` 同一层（`connector/src/handlers.ts`），
**不占 DSH 的 `@Remote` 面**（那是 DSH 的方法；这是我们自己加的面，与
`agentPresets.list` 同一条纪律：DSH 没有的就自己聚合，但**聚合规则要写在笔记里**）。

返回形状（**不从 DSH 翻译，从手机已能拿到的两份东西加**）：

```ts
{
  sessions: number,              // 参与汇总的会话数
  grandTotalTokens: number,      // 全部会话的 token 总量
  cacheHitRate: number | null,   // 缓存命中率（与单会话同一个算法）
  byDay: [{ day: '2026-10-19', tokens: number }],  // 近 30 天，按天
  topSessions: [{ sid, title, tokens }],           // 用量前 5
}
```

### 2. 聚合的数据来源（**这是方案的核心，有两种取法**）

| 取法 | 做法 | 代价 |
|---|---|---|
| A. **遍历会话读投影** | `session.list` 拿全部 sid，逐个 `session.projections` 读 `tokenUsage` | N 次 IPC；会话多时（真机这台 20+）要几百毫秒 |
| B. **连接器本地记账** | 订阅期把每个 `ev` 的 `assistant/message.data.usage` 累加进自己的存储 | 只覆盖**插件在线期间**的会话；历史的一次性汇总拿不到 |

**选 A**：用户要的是"从电脑上看总量"，而 B 会给出一个"只有我连过的那部分"的数字 ——
那看起来像总量，其实不是，比没有更糟（项目纪律：不给看似数据的假数据）。
A 的代价是 N 次 IPC，但 `session.list` 已经在启动时拉过，sid 是现成的；
且可以**只对 visible 会话求和**（与 `sessionVisible` 同一条规则，子智能体不汇总）。

### 3. 为什么不做成"实时推送"

`ev` 帧带 sid，连接器可以维护一个累加器随帧推送。但那会让"汇总"有**两个真值源**
（推送的累加值 vs 拉取的投影值），而两者在会话被别的客户端跑过时会不一致。
**只做拉取**：手机进设置页/统计页时调一次，`session.projections` 是唯一真值。

## Alternatives considered（否掉的）

- **手机侧本地汇总**（把每个会话的 tokenUsage 累加在 sqflite 里）：手机只在
  **订阅某个会话时**才收到它的 `tokenUsage`（投影随 `ev` 走），
  所以手机侧天然只能汇总"看过的那些"。否。
- **改 DSH 加一个全局投影**：DSH 是只读参考源码（`AGENTS.md` §5），
  且改它会影响所有客户端。否。
- **推送 + 拉取双轨**：两个真值源，见上。否。

## Consequences（若实施）

- 收益：设置页/统计条能看到"这台电脑一共用了多少"，而不只是当前会话。
- 代价：`usage.summary` 是新方法，要同改三处（`tools.md` 的方法数、契约 §5.7 的表、
  `memory.md` 的"方法面 x/31"）+ 连接器单测 + app 侧读取与呈现。
- **性能**：N 次 IPC 在 20 个会话时约几百毫秒；设置页是用户主动进的，
  一次等待可接受。若实测慢，退路是"只汇总最近 7 天有更新的会话"
  （`session.list` 的行带 `updatedAt`，过滤在连接器做，规则写进笔记）。

## 实施顺序（下一轮照这个走）

1. 连接器：`handlers.ts` 加 `usage.summary`（遍历 visible 会话读 `tokenUsage` 投影求和）；
2. 契约：§5.7 加一行 + 三处计数同步；
3. app：`AppModel` 加 `usageSummary`（`session.projections` 之外的**新方法**读取），
   设置页「通用」加一行「用量统计」或统计条加一个汇总 chip；
4. 测试：连接器单测（聚合规则：visible 过滤 / 全零投影的会话算 0 不计入
   —— 与 `memory.md` 教训 4 同一条：**"空"有两种表达**）。
