# Agent Note: 运行中动效 —— 共享 ticker 的扫光 + 流末尾的活时钟

Status: implemented

## Problem

用户原话：「没有这个动效还以为卡了」。

DSH 的"过程"有三层动效（`packages/client/ui-primitives/src/TextShimmer.tsx:37-57` +
`TextShimmer.module.css:34-87`、`StateDot.module.css:37-83`、
`ui-chat/src/client/chat/RunningStatus.tsx:20-41`），手机侧**一层都没有**：

- 聊天流里零动效。运行中的工具卡只是把图标换成静态 `loading` 字形
  （`app/lib/ui/chat_turns.dart:341-345` 那一版），`_DisclosureHeader` 连 `running`
  参数都没有；
- 流末尾没有运行条：`liveText != null` 时有 `_LiveTurn`，但**两个工具之间**
  （没有流式正文、等结果时）屏幕上什么都没有；
- 全 App 的转圈只在顶栏与子智能体树。

## Decision

### 1. 扫光：全 App 一个 ticker

`app/lib/ui/dsh_shimmer.dart`：

- `DshShimmerHost`（`MaterialApp.builder` 里挂一层）持**唯一**的 `AnimationController`
  （1.5s 周期）+ 一个 `Stopwatch` 单调时钟；
- `DshShimmer(active: …)` 只在**真的在跑**时 `attach()`，跑完 `detach()`；
  引用计数归零就 `stop()` —— 一行都不跑时**不留空转 ticker**；
- 绘制用 `ShaderMask(blendMode: srcIn)` 把**同一段文字再画一遍**，遮罩是一条
  105° 带子：相位 0→1 映射到 `translateX(-100% → +100%)`，`steps(48)` 离散化，
  2/3 之后停在右边缘（对应 CSS 的 `66.6667%, 100%`）；
- `MediaQuery.disableAnimations`（`prefers-reduced-motion` 的 Flutter 对应物）为真时
  整层不画；
- 染色从 `labelPrimary` 按 DSH 的 `color-mix` 比例派生（深色 45% / 浅色 30%），
  不新增字面色值。

接入点（都只在 `running` 为真时扫）：

| 行 | 判据 |
|---|---|
| 工具卡的名字 | `ToolCard.status == ToolCallStatus.running` |
| 命令卡 / 思考行的标题（`_DisclosureHeader`） | `CommandCard.status == running` |
| 轮组头（`TurnProcessRow`） | 新增 `running` |
| 运行条的文案 | 常真（它只在跑时存在） |

**思考行（`_CollapsibleNote`）没有扫光** —— 不是漏了：`ReasoningItem` 没有"还在流"
的字段（`AssistantTurn.reasoning` 只是一段字符串），硬加就得编一个状态。
这属于"做不了的写进文档"，见 `docs/subsystems/running-cues.md` §4。

### 2. 运行条：秒数从电脑侧来，手机只走秒

`RunningBar`（`app/lib/ui/chat_page.dart`）挂在流末尾（`reverse: true` 的 index 0）：

- 文案照 DSH 的 locale：`深度求索中` / `深度求索中，用时 N 秒 ···`
  （`ui-chat/src/client/locale.ts:89-90`；`Math.max(1000, now - startTime)` 同 `RunningStatus.tsx:29`）；
- 每 `1000ms` 重算一次（`message-chrome.ts:13` 的 `LIVE_RUN_CLOCK_INTERVAL_MS`）；
- 起点 = **`turn/start` 事件的 `time`**（电脑侧的时刻），兜底读 `trajectory` 投影里
  那一轮的 `startTime`；拿不到就只说「深度求索中」，**不编秒数**。

### 3. "在跑吗"：改从事件流判（这条是本轮真机逼出来的）

原本照开工单写的是 `session.list` 的 `running`。真机实测（`d61cf622`）：
一轮跑了 40 秒，运行条**整轮都没出现** —— 那张表只在连上 / 收口 / 打开面板时重读
（`app_model.dart:2559` 的注释），轮次进行中它是**旧值**。

改成事件流判据（`AppModel._runningSids` / `_turnStartedAt`）：
`turn/start` → 记在跑 + 记起点；`turn/end` → 收。事件本身就是**电脑侧**的事实，
边界与时间都来自它；`session.list` 的 `running` 只留作打开会话那一刻的初值。

## Alternatives considered

1. **每行一个 `AnimationController`（照 DSH 每个 `TextShimmer` 一个 CSS 动画）**
   - 最强理由：与 Web 结构一一对应，行自己管自己的相位，代码最短。
   - 为何被否：一屏几十个运行行就是几十个 ticker；`dsh_state_dot.dart:83-95`
     已经为这件事把控制器改成"只在该转时建"，并记了跨用例污染测试的坑。
     共享一个控制器 + 引用计数同样保真，代价只是相位由宿主时钟算。
2. **用 `MediaQuery.textScaler` / 全局 `Transform.scale` 做"动效"**
   - 最强理由：一行代码，所有文字一起动。
   - 为何被否：那会把图标、间距、触达区一起放大（字号那条同一理由），
     而且它不是"扫光"，是整块缩放。
3. **插入鲸鱼尾 APNG（DSH 的 `running-whale@2x.png` + CSS mask）**
   - 最强理由：与 Web 逐像素同源，品牌感强。
   - 为何被否：用户 2026-10-22 明确选"用已有 loading 字形转圈"—— 零新资源、
     不用确认素材版权；动效点来自转圈 + 活时钟，观感仍是"在动"。
4. **运行条读 `session.list` 的 `running`（照开工单原文）**
   - 最强理由：只读一个字段，不用在 `AppModel` 里维护状态。
   - 为何被否：真机上它是旧值（见上），运行条整轮不出现 —— 等于没做。
     事件流判据同样是电脑侧事实，而且**实时**。

## Consequences

- 收益：运行中的每一步都看得见在动；两个工具之间有一条"深度求索中，用时 N 秒"
  的活时钟；静止的行不闪。
- 代价：
  - `DshShimmerHost` 要挂在 `MaterialApp.builder` 上：挂不上（例如单测直接 pump
    某个页面）时 `DshShimmer` **原样返回子节点**，不闪也不崩。
  - 扫光是**常驻重绘**：只在有运行行时开，跑完就停 —— 判据是
    `transientCallbackCount`（单测钉住 3 行 = 1 个 ticker、全停 = 0）。
  - `AppModel` 多了两个按 sid 的集合（`_runningSids` / `_turnStartedAt`）。
    断线时若没收到 `turn/end`，它们会留到下一次 `turn/end` —— 这是已知缺口，
    运行条会一直转到下一次收口（与"轮次真的结束了但事件没到"同形）。
- 单测 `app/test/shimmer_test.dart` 七条：静止不建叠层 / 3 行 1 个 ticker /
  全停归零 / `disableAnimations` 不画 / 工具行 running 才闪 / 运行条秒数走 /
  没有起点不编秒数 + `runningOf` 与 `turnStartedAtOf` 的事件流判据。
  **两处变异校验**：① 去掉 `_attached` 门（静止也画）⇒ 三条断言红；
  ② `detach()` 改成空操作 ⇒ "全停归零"那条红。直接落点那条仍绿（证明它钉的是过程）。
- 真机证据（`d61cf622`，`shots-2026-10-22/`）：
  - `c-06.png` → `c-08.png` → `c-13.png`：同一条运行条的秒数 `18 秒 → 23 秒 → 36 秒`
    （蓝色扫光文字 + 转圈字形）；
  - `f-08.png`：同一会话收口后**运行条消失**（3 轮 8 步），静止的行不闪；
  - **没抓到的一张**：工具行自己的扫光。免费渠道的思考阶段要吃 1–2 分钟，
    真正 `sleep` 的那 120 秒落在采样间隙里；工具行与运行条走的是**同一个**
    `DshShimmer`，而它已由单测（`ToolCard` running/completed/failed 三条）与
    运行条的实机动画共同覆盖。下一轮如果要补，判据是"拖到工具执行中截一张"。
