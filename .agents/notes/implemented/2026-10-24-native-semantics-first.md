# Agent Note: 宿主语义优先 —— 不新增 DSH 没有的规则

Status: implemented

## Problem

2026-10-23 这一轮里，用户连着两次点破同一个毛病：

1. 先说："**DSH 原生是啥样就啥样，原生啥规则就啥规则**，不要自己发挥"——
   当时我刚给审批加了"10 分钟没人答就放弃等待"（`hold`）和一条"未处理记录"，
   理由是"不能无限挂"。但 DSH 的浏览器**本来就没有超时**：那张卡一直挂着，等人答或等 `signal`。
2. 再说："什么设置不让手机答？什么只要在线就让手机答？……我现在两边都会弹谁答不都一样，
   这两个有啥意义"——当时我刚把 host answerer 换成 gateway 的 client，却还留着**三档接管开关**
   （`approvalTakeover: never / foreground / always`）和它的仲裁判定。那套是"抢"时代的产物：
   抢到桌面就看不到，才需要"什么时候抢"。两边都收之后，没有"谁接管"这回事。

两次的共同形状：**替宿主做了一个它已经做过的决定**，并为此发明了一整套配套概念
（看护超时 → 未处理记录 → fail-closed 指标；档位 → 仲裁 → 排序 → fixture 16）。

## Decision

**宿主语义优先，不新增 DSH 没有的边界。** 判据是三句话，写进 `AGENTS.md` 的常驻军规：

1. **这条规则删掉，DSH 会不会已经给出答案？** 会 ⇒ 我们不该有。
   （例：没人答怎么办 → DSH 就是一直等；所有 client 都委托 → DSH 自己给 `unavailable`。）
2. **它是在补"我们这条通道没有的东西"，还是替宿主做决定？** 补通道可以，替决定不行。
   （例：`$events` 流的重连退避、逐帧校验 = 补通道；审批超时、"谁接管" = 替决定。）
3. **它写进 `docs/` 了吗？同一件事是不是只有一处表达？** 没有就写；两处就砍一处。

### 已经按这条撤掉的（同一批提交 `08fe52d` 前后）

| 撤掉的 | 为什么它是自创 |
|---|---|
| 审批看护计时器（`Watchdog` / `DEFAULT_APPROVAL_GUARD_MS` / `approvalWatchdogMin`） | DSH 的审批没有超时（浏览器的卡一直挂到有人答或 `signal` 中止） |
| "未处理记录" + `METRIC.failClosed` + `hold`（沉默） | 都是为超时发明的出口；DSH 自己的兜底是 `unavailable` |
| 三档 `approvalTakeover` + `decideTakeover` + `fixture 16` + `takeover.mjs` + store 的 `takeover` 表 | "抢"时代的仲裁；两边都收之后没有"谁接管" |
| 端口前的"设备离线就不呈示"兜底 | 与"手机连着就是 client"重复：连着就有投递，不连就没有 |

配套的"补回去"是：不参与 → **`next()`**（DSH 的委托语义；只有所有投递都 `next` 才交还 Host）。

### 代价（如实）

- 协议断言 **486 → 454**（fixture 16 那 32 条随规则删除；两侧同时删、仍对等）。
- 连接器 **618 → 611**（删掉的断言都跟着被删的行为走，不是放宽）。
- 这是本仓**唯一**两处破了"门禁只许升"，理由都是**契约规则本身被删**，已在
  `memory.md` 与提交信息里写明。

## 还要往下查的

这条原则不能只落在"这一轮删掉的三处"上。已知仍有若干"我们可能替 DSH 做了决定"的地方
（`question-call.ts` 的身份推断、审批对 `callId` 的依赖、App 的 `danger-full-access` 入队过滤、
重连重建运行态…），全部登记在一张**总账**里，带"为什么可疑 / 怎么求证 / 初步归类"：

- `.agents/notes/proposed/2026-10-24-native-rules-audit.md`（总账）
- `.agents/notes/proposed/2026-10-24-next-round-native-rules-audit.md`（下一轮提示词）

Note: 三处具体删除的因果与真机证据见
`.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`。
