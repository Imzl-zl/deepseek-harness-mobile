# Agent Note: 会话流的轮组（turn 分组 + 可折叠过程）

Status: 被 `implemented/2026-10-22-turn-groups-phase-1.md` 取代（阶段 1 已落地；
阶段 2「语义过程组」仍未做）。本篇是**当时的方案**，结论不改。

> 取代处的两处差异：① 分组边界落地时改成"取条目自己的轮号"（`ChatItem.turn`），
> 比本篇写的"扫 `turn/start` 记账条目"更稳 —— 历史窗口里没有 `turn/start` 也能分组；
> ② 组头仍留在轮次末尾（本篇就是这么定的），而 DSH 其实在轮次开头，差异已写进
> `docs/subsystems/turn-groups.md` §4。

## Problem

用户 2026-10-22 当场指出：Web 与 App 的会话流**结构不同**，不是样式差。

- Web：一轮跑完后是一条可展开的**控制行**（`已完成，用时 8s ⌃`），组内是
  「已完成分析」「执行了命令」这种**语义化过程组**，再里面才是思考行 / 工具行，
  每层都能各自展开。
- App：**完全平铺** —— 用户消息、思考、每个工具卡、助手正文、轮次收口行
  （`TurnProcessRow`）依次排开。一轮 8 次工具就是 8 张卡片铺两屏。

后果不是审美：① 没法"把这一轮收起来看下一轮"；② 设置里「工作步骤展示」的四档
只能作用于"单张工具卡的明细展不展开"，**没有组可折**；③ 收口行
（`第 4 轮 · 5 分 21 秒 · 2 条消息 · 1 次工具`）现在只是纯展示，DSH 那个位置
是**可点的折叠开关**（`TurnProcessNodeView.tsx:20-30`）。

## 事实（Web 侧，逐条带行号）

1. **两层，不是一层**：整轮控制行 `TurnProcessNodeView`
   （`packages/client/ui-chat/src/client/chat/TurnProcessNodeView.tsx:10`）与
   过程组组头 `ChatGroupSeat`（`.../chat/ChatGroupSeat.tsx:92-132`，定义在
   `.../conversation-nodes/process-groups.ts:297-303`）。子行是第三层。
2. **整轮控制行只在轮次关闭后存在**：`TurnProcessNodeView.tsx:18`
   `if (turn?.status !== 'closed') return null` —— 运行中**没有**这一行，屏幕上
   是"组头显示实时活动 + 流末尾活时钟"（`ChatGroupSeat.tsx:103-127` +
   `RunningStatus.tsx:20-40`）。我们已经有的运行条正是后者（`running-cues.md` §2）。
3. **折叠默认态**：过程组默认**收起**（`ChatGroupSeat.tsx:137` 的 `useDisclosure`
   初值 `false`）；只有 `detailed` 档在运行中直接展示组体、`verbose` 档全部展开
   且不画组头（策略表 `.../presentation-policy.ts:23-52`）。
4. **边界是客户端自己算的，host 不下发分组**：Web 消费 `turn/start` / `turn/end`
   事件构造 `TurnLocation`（`packages/client/ui-conversation/src/client/conversation/location-index.ts:444-503`），
   组切分在 `process-groups.ts:147-165`。`turnOutline` 投影**只**喂右侧轮次轨道
   （`.../chat/ChatView.tsx:76-82`）。⇒ 手机也不可能"复用电脑侧算好的边界"。
5. **时长口径**：`Math.max(1000, end.time - start.time)` 再 `Math.floor(ms/1000)`
   （`.../chat/message-chrome.ts:54-64`），**不读 `durationMs`**。
   我们这边**必须反过来**：只读 `trajectory` 投影的 `durationMs`
   （`docs/subsystems/trajectory-page.md`；`app/lib/model/trajectory.dart` 的
   文件头写了"这里没有一处减法"）。
6. **折叠态存哪**：组展开态是组件本地 state（`use-disclosure.ts:11-21`），外层真
   隐藏时重置；整轮折叠态在每会话**纯内存** store（`stores.ts:50-61`），不落盘；
   只有偏好（展示密度 / 收起时机）在 Host 设置文档。

## 落地端现状（决定工作量的三条）

1. 流是**一条平铺的 `ChatItem` 表**（`app/lib/ui/chat_page.dart` 的 `_ChatTab` →
   `_itemOf`，`model/chat_item.dart` 的 `sealed class ChatItem`）。
2. `turn/start` **已经**落了一条不可见的记账条目（`OtherItem`，见
   `app/lib/data/app_model.dart` 里 `_onDelta` 的注释）—— 也就是说**轮次边界
   已经在流里了**，只是没人用它分组。
3. 但**只有两类条目带 `turn`**：`TurnOutcomeItem` 与 `TurnProcessItem`
   （`model/chat_item.dart:307,438`）。真机事件里 `tool/call` / `tool/result` /
   `assistant/message` 的 `data.turn` 都有，**`user/message` 没有**；
   而顺序上 `turn/start` 在前、`user/message` 紧随其后（真机日志
   `session-4f50055e…`：`93 turn/start turn=5` → `96/97 user/message` → `98 assistant/message turn=5`）。

## Proposal

### 阶段 1：整轮组（最小可用，建议先做这个）

1. **投影层加 `turn`**：`MessageItem` / `ToolCallItem` / `CommandItem` /
   `RetryItem` / `CompactionItem` 各加一个 `int? turn`，值取 `event.data['turn']`
   （有就填，没有就 `null` —— 不猜）。`user/message` 没有这个字段，靠位置归组。
2. **分组算法（纯函数，可单测）**：扫一遍条目表，遇 `OtherItem`（`turn/start` 的
   记账条目）开新组；组内条目按顺序收；`TurnProcessItem` / `TurnOutcomeItem`
   收口。`user/message` 归到**它前面最近的那个 `turn/start`** 所在的组；
   组之前的孤立用户消息（还没有 `turn/start` 的那一拍）自成一组、不折叠。
3. **组头 = 现有 `TurnProcessRow`**：加 `expanded` 与 `onToggle`，右侧放 chevron
   （DSH 是 `IconChevronDownOutlineRegular` + `rotate(180deg)`，
   `TurnProcessNodeView.module.css:37-39`）。文案不动（已有
   `第 N 轮 · 用时 · 条数 · 工具数`，`chat_turns.dart` 的 `TurnProcessRow`）。
4. **折叠语义**：
   - **运行中的轮次 = 平铺**（组头不出现）。这与 DSH 同一条
     （`status !== 'closed'` 时返回 null），也保住"边跑边看"的体验；
   - 轮次关闭的瞬间：出组头，组体按**收起时机**的设置收起/保留；
   - 点组头 = 展开/收起该轮（`AnimatedSize` 或直接换子表；`reverse: true` 的列表
     里换格数会让位置跳，见风险 2）。
5. **默认态**：默认**收起**（照 DSH 的组默认 `false`），但**只在轮次关闭后**。

### 阶段 2：过程组（语义化子组，可选）

一轮之内再按"分析 / 命令 / 编辑 / 读文件"聚成 2–4 个语义组头
（`process-groups.ts` 的定义；DSH 文案 `已完成分析并执行了命令`）。
手机上我倾向**先不做**：390dp 宽、一层组头已经占掉 40dp 高，两层组头在触屏上
点开两下拉到正文，收益不抵成本。等阶段 1 上了真机看过再定。

### 与 `trajectory` 投影的关系（**不复用它的分组**）

- `trajectory` 给的是"每轮 + 每步（assistant / tool / compaction）的起止与时长"，
  **没有思考正文、没有用户消息、没有审批/提问卡** —— 拿它当分组源会把流切成两半。
- 它只负责**时长**：组头/详情里的用时读 `durationMs`（手机侧零减法），
  与 `docs/subsystems/trajectory-page.md` 一致。
- 两边的 `turn` 编号是同源的（都来自事件 `data.turn`），可以按 `turn` join
  去补时长；join 不上就**不显示时长**，不编。

### 对「工作步骤收起时机」那行设置的影响

- 这行（DSH `ui-chat.collapseTiming`，`chat-settings.ts:15,21`，两档
  「回答结束后 / 下次有新消息时」，默认 `回答结束后`）**在有轮组之前没有语义** ——
  现在设置页里根本没摆它（`docs/settings-porting-notes.md` §1 记着这一条）。
- 阶段 1 落地后它才成立，语义是：组体在**轮次结束时**收起（默认），
  还是**保留展开直到用户发下一句**（`next-input`）。
- 存储走**手机本地**（和我们已有的「工作步骤展示 / 性能与用量」同一条：
  `AppModel` 的 `kTranscriptViewKey` 模式），**不**进电脑侧设置 ——
  D 那三条可写的 `(ns,path)` 保持不动（`docs/subsystems/settings-and-versions.md`）。

## Alternatives considered

1. **只让收口行（`TurnProcessRow`）可点，点了把"该轮之后的内容"折叠**（不改投影）
   - 最强理由：不动数据层，一天能做完。
   - 为何被否：`ChatItem` 里没有可靠的轮归属，只能按"收口行在表里的位置"倒推组体；
     而历史分页/`turn/start` 落在未加载那一页时会算错组（`memory.md` 的"过程摘要在
     历史窗口不全时如实降级"就是这么来的）。省下的是投影层那一个字段，代价是一套
     位置推断的第二真值。
2. **复用 `trajectory` 的 turns 当分组源**
   - 最强理由：电脑侧已经算好轮与步的边界，手机不用再判。
   - 为何被否：见上——它不含思考正文与用户消息，用它分组会把流拆成"时间轴行 +
     其余散条"，比平铺更乱。它只适合轨迹页。
3. **照 DSH 一次做两层（整轮组 + 语义过程组）**
   - 最强理由：与 Web 结构完全对齐，一次到位。
   - 为何被否：两层组头在 390dp 上把一轮压成"两次点击才看到正文"，而用户要的是
     "少一层结构"的补齐，不是"再多一层"。先做整轮组，看过真机再加第二层。
4. **不做分组，只加一个"折叠全部工具卡"的全局开关**
   - 最强理由：不引入结构。
   - 为何被否：那是 `TranscriptView` 已有的四档能表达的东西（`compact` 已经是
     "工具折叠成一行"），做了也解决不了"整轮收起"和"用时/条数"的组头。

## 工作量与风险

| 项 | 量 | 说明 |
|---|---|---|
| 投影层 `turn` 字段 | ~6 个类 + `_onDelta` 里一处赋值 | 低风险，纯加字段 |
| 分组纯函数 + 单测 | ~120 行 + 8 条用例 | 需覆盖：无 `turn/start`、跨页边界、运行中、孤立用户消息 |
| `TurnProcessRow` 加折叠 | 小 | 加 `expanded` / `onToggle` / chevron |
| `_ChatTab` 改"组 → 条目"两级渲染 | 中 | 牵动 `key`（现在是 `itemId`）、跳转钮锚点、自动滚底 |
| 设置行「工作步骤收起时机」 | 小 | 本地偏好 + 落盘 + sheet |

风险（都在真机才暴露）：

1. **`reverse: true` + 变格数**：收起会减少列表格数，正在看的位置会跳。DSH 是
   `AnimatedSize` + 保 scroll offset；我们要在收起/展开后按"被折叠块的相对位置"
   调 `jumpTo`，否则用户点开一轮时正文从屏幕上消失（对应 `tools.md` 的
   "widget 测试的默认视口比真机大"那个坑，得真机看）。
2. **历史窗口不全时组头不完整**：`turn/start` 在未加载的更早一页 ⇒ 该组没有起点。
   处置照现有纪律：**如实降级**（该组不显示时长/条数，或被截断的组不折叠），
   不补零、不猜。
3. **`itemId` 复用 key 的既有不变量**（`widget_test` 有一条"展开后换一份 items
   仍然展开"）必须继续成立：组展开态要按 **turn 号**存，不能按列表下标。
4. **子智能体 / 命令卡 / 审批卡也在流里**：它们要么进组（工具/命令），要么不进
   （审批是"等用户"，放组里收起会让用户看不到待决策），需要逐类定归属 ——
   这一条要在实现前**过一次真机会话**逐类点名，别在代码里就地拍板。

## 判据（实现时要给出的证据）

- 纯函数：分组切分 8 条（含跨页、无起点、运行中、孤立用户消息）。
- widget：一轮 3 次工具 + 2 段思考 → 关闭后是 1 个组头 + 正文隐去；点组头展开
  后条目数回到原值；展开态按 turn 存（换一份 items 仍展开）。
- 真机：一轮 8 步的会话，收起后一轮只占 1 行；点开位置不跳；运行中的一轮仍平铺
  （没有组头）。
