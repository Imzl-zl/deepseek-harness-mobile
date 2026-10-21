# Agent Note: 子会话要两种「非普通会话」的对待 —— 带父级的地址，和唯一的写入口

Status: implemented

## Problem

隔离实例真机验收（2026-10-21 晚）当场抓到两条，症状都像"连上了但没内容"：

1. **点目录行进子会话 → 一片空白**，还配着「这个会话还没有内容 / 在电脑上继续它」的空态文案。
   连接器日志（临时打点，查完即撤）给出根因：
   `RemoteError: subagent Sessions require their durable parent address`。
   宿主对 `{kind:'session'}` 形式的子会话地址**直接拒绝**
   （`packages/api/session-controller/src/history.ts:347-352`），
   而连接器的 `follow` 与 `page` 一律用 `sessionAddress(dshSessionId)`。
2. **在可继续子会话里发消息 → 「发送失败」**，原文
   `ProtocolException(internal): session "ca1ecdcc-…" is owned by subagent routing`。
   宿主要子会话的消息走 `subagents.prompt`（`packages/subagent/subagent/src/index.ts:447`），
   而我们只有 `session.prompt`。

两者都**逃得过单测**：替身从不按宿主规则拒绝，所以"子会话白屏 / 发不出去"只在真机出现。

## Decision

**子会话在连接器里走两条专用路径，判据都来自 `session.list` 行**：

1. **地址**：`dsh/sessions.ts` 的 `resolveSessionAddress(source, sessionId)` ——
   行是 `subagent` 且有 `parentSessionId` 就给
   `{kind:'subagent', parentSessionId, childSessionId, mode:'unknown'}`，否则普通地址。
   `mode: 'unknown'` 跳过模式校验（`history.ts:375`），所以不必先读 catalog。
   `follow`（订阅）与 `page` / `refetch`（翻页）**两处都改** —— 只修一处的话
   "能看见内容但翻不动历史"，是同一类地址规则的半截。
2. **写**：契约 §5.7 加 `subagent.prompt`（`requestId` 幂等），
   handler 从同一份 `session.list` 行取 `parentSessionId`，交给
   `SubagentsPort.deliver` → `subagents.prompt({mode:'continuable', delivery})`。
   不是子会话就回 `protocol/bad-frame`（客户端用错方法，不伪装成连接问题）。
   手机侧 `_send()` 在子会话里换方法名，**参数形状与 `session.prompt` 逐字相同**。

顺带把「面板指标只在重连后更新」也归到同一个根因家族：`session.list` 的行只在
**连上 / 建会话**时拉过，而子会话是在回合里出现的。补两个时机：
**打开子智能体面板**（`_refreshSubsMetrics`，抽屉打开 / 切到该页 / 切换 sheet）与
**当前会话的回合结束**（`_onDelta` 里 `turn/end` 且该会话目录非空）。
不加定时器：这一层没有推送面，逐帧拉会把一次会话变成一串 `session.list`。

## Alternatives considered

1. **让手机在 `openSession` 时把父级 sid 一起传上来**
   - 最强的理由：连接器不用自己查清单，一次往返就够。
   - 为何被否：父级是**导航记忆**（`_subagentReturnFrom`），它是界面状态；
     而宿主要的是**持久父级**（`header.parentSession`）。两者大多数时候相同，
     但从"切换兄弟""系统返回后再进入"等路径进来时并不保证。
     用界面记忆当协议字段，错的时候是**静默**的（宿主只回一句 unauthorized）。
2. **在连接器里维护一张 `child → parent` 缓存（订阅时填）**
   - 最强的理由：省掉每次 `list()` 的一次往返。
   - 为何被否：新子会话是回合里冒出来的，缓存必然有"还没填"的窗口，
     而那个窗口正好是用户点进去的那一刻。一次 `list()` 换掉一类竞态，值得。
3. **`follow` 先按普通地址试，失败再换子会话地址重试**
   - 最强的理由：不查清单也能自愈，且只在子会话上多一次失败。
   - 为何被否：那是"兜底"形状——错误被当成控制流，而重试还会让第一次失败
     在日志里看起来像真故障。判据（行上的 `subagent` + `parentSessionId`）本来就在手里。
4. **子会话的输入栏也做成只读，绕过 `subagents.prompt`**
   - 最强的理由：改动最小，且不会有"发不出去"的失败。
   - 为何被否：可继续子会话**本来就能收人写的消息**（DSH 的原生能力，
     `control-types.ts:94-112` 的 `delivery: queue|steer`）。把它做成只读是
     用一个功能缺失掩盖另一个，而且与 Web 的行为相反。
5. **面板指标改成轮询（面板开着时每秒拉一次）**
   - 最强的理由：数字会一直新鲜。
   - 为何被否：一次会话会变成上百次 `session.list`；而"打开那一刻 + 回合结束"
     已经覆盖了用户真正会看的那两个时机。

## Consequences

- 收益：子会话能打开、能翻历史、能继续对话；顶栏那枚「N 个子智能体，正在运行」
  与行上的 token / 时长在真机上真的会变（验收时采样到 `1 个子智能体，正在运行`）。
- 代价：每次打开子会话多一次 `session.list` 往返（`resolveSessionAddress`），
  每次打开面板 / 每个回合结束各多一次。都是**一次**，不是周期性的。
- 代价：`subagent.prompt` 只服务 `continuable`；一次性 / 外部任务的子会话在手机上
  是只读框，走不到这里。将来若出现"给一次性子会话发消息"的需求，那是另一个决定。
- 代价：`SessionsPort` 之外多了一个 `addressOf` 注入点（`SessionSubscriptionsOptions`），
  替身要显式给 —— 这是有意的：让"地址从哪来"在类型上就看得见。
- 仍未验：孙级（宿主 `maxDepth` 默认 1，只能派直接子级）、一次性子会话
  （本 profile 两个 in-process 后端都只产 `continuable`）。
- 验证：连接器 561 项（新增 `resolveSessionAddress`、订阅地址、翻页地址、
  `subagent.prompt` 两条）；App 993 项（新增"打开面板重拉清单""回合结束重拉"
  "普通批次不重拉""子会话发送走 subagent.prompt"四条，其中两条做过变异校验）；
  真机逐条判据见 `docs/subsystems/subagent-page.md` §7。
