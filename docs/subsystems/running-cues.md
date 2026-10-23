# 运行中动效（扫光 / 转圈 / 运行条）

聊天流里**只有真的在跑的行**会动：工具卡的名字、命令卡与思考行的标题会扫光，
流末尾有一条带活时钟的运行条。静止的行不许闪。

轮组收口行（`第 N 轮 · 用时 · 条数`）**不扫光**：它只在轮次收口后出现
（`turn-groups.md` §3），永远收不到"在跑"。

## 1. 扫光（`app/lib/ui/dsh_shimmer.dart`）

照 DSH 的 `TextShimmer`（`packages/client/ui-primitives/src/TextShimmer.tsx:37-57` +
`TextShimmer.module.css:34-87`）：

| 参数 | 值 | 出处 |
|---|---|---|
| 周期 | 1.5s | `TextShimmer.module.css:63` |
| 起始延迟 | 0.3s（每行各自从"开始跑"那刻算） | `:64` |
| 步进 | `steps(48, end)` | `:65` |
| 扫动区间 | `translateX(-100% → +100%)`，到 66.6667% 停住（余下 1/3 是空档） | `:69-77` |
| 遮罩 | 105° 线性渐变：`transparent 0% / black 40%..60% / transparent 100%` | `:39` |
| 染色 | `--dsw-alias-label-shimmer` = `labelPrimary` 45%（深色）/ 30%（浅色） | `design-platform.css:342` / `:224` |
| 减弱动效 | `MediaQuery.disableAnimations` 为真时**整层不画** | `:79-87` |

实现：`ShaderMask(blendMode: srcIn)` 把同一段文字再画一遍，遮罩随相位移动；
**真实文字不动，动的是带子**（与 DSH 的"两层反向位移相抵"等价）。

**全 App 只有一个 `AnimationController`**（`DshShimmerHost`，挂在 `MaterialApp.builder`）。
行只在自己 `active` 时挂上去，`active` 归零就停 —— 判据是
`tester.binding.transientCallbackCount`：3 条运行行 = 1，全停 = 0
（`app/test/shimmer_test.dart`）。

**真机证据（工具行自己的扫光）**：`shots-2026-10-22/g-213439.png`（`run_code` 行 +
loading 字形 + 运行条「用时 1 分 54 秒」）；同一行矩形的相邻帧差分显示变化只落在
一个约 40px 宽、随时间左移的窗口里，行内其余像素不变
（放大对照 `h3-tool-row-band-zoom.png`）。

## 2. 运行条（`RunningBar`，`app/lib/ui/chat_page.dart`）

挂在流末尾（`reverse: true` 列表的 index 0，`_ConversationFlow` 里当虚拟尾条目）。

| 部分 | 取值 | 出处 |
|---|---|---|
| 文案 | `深度求索中` / `深度求索中，用时 N 秒 ···` | `ui-chat/src/client/locale.ts:89-90` |
| 时钟 | 每 `1000ms` 一次 | `ui-chat/src/client/message-chrome.ts:13` |
| 下限 | 不足 1 秒按 `1 秒` 说 | `RunningStatus.tsx:29` 的 `Math.max(1000, …)` |
| 图标 | 已有 `loading` 字形转圈（**不引鲸鱼尾 APNG**） | 用户 2026-10-22 决定 |

**秒数只能来自电脑侧**：起点是 `turn/start` 事件的 `time`（兜底：`trajectory` 投影里
那一轮的 `startTime`）；拿不到就只说「深度求索中」，不编数字。
手机侧唯一允许的减法就是这个活时钟；**跑完的时长仍然只读投影的 `durationMs`**。

## 3. "在跑吗"判据：宿主的推送（`status` 帧），不是自己数事件

`AppModel.runningOf(sid)` 只读 `_runningSids`，而它只有**两个写入面**（都走 `_setRunning`）：

1. **`status` 帧**（实时）：连接器把宿主 `api-session/status` 原样转发过来
   （`connector/src/protocol/frame.ts` 的 `status`，载荷 `{running}`）。这正是 DSH 浏览器的
   数据源（`packages/api/session-controller/src/client/index.ts:118-119` → `manager.ts:726-734`）。
2. **`session.list` 那一包**（初值与重连纠正）：**按原样覆盖**，与 DSH 浏览器同一条
   （`manager.ts:248-253` 的 `session.handleRunning(summary.running)`）。

历史两课都在这条线上：**不能用快照当实时判据**（2026-10-22 一轮 40 秒整轮没出运行条 ——
那张表只在连上/收口时重读），**也不能把"快照 OR 事件"叠起来**（旧快照的 `true` 永远关不掉，
电脑侧收口后 App 还转 5 分钟）。所以实时的那一半交给宿主推送，快照只在读到时覆盖一次。

**没有"轮次代号护栏"了**：那套东西是给"自己数 `turn/start` / `turn/end` + 重连重建"用的，
事件推算整个删掉之后它没有对象。断线期间收口的一轮由重连后那一包 `session.list` 纠正，
之后的变化由 `status` 帧维护。

三处读同一个真值：运行条（`_ConversationFlow.running`）、输入栏的「排队发送」与
「工作步骤展示」的运行中展开（`chat_page.dart` 的 `_running`）、子智能体行的状态。

`turnStartedAtOf(sid)` 读 `_turnStartedAt`（`turn/start` 的 `time`），兜底读
`trajectory.runningTurn.startTime`（**只对当前会话**）。**起点仍来自事件**：推送里没有时间。
收口（`status{running:false}`）会一并清掉起点。

## 3.1 判据

- `app/test/shimmer_test.dart`：`status{true}` 起、`status{false}` 收；**快照说在跑时
  `status{false}` 也必须能停**（后者走真 `session.list` 解析器）；`turn/start` 只提供起点。
- `app/test/running_reconnect_test.dart`：两个写入面各一条 ——
  断线期间收口（重连那包 `session.list` 说 `false`）⇒ `runningOf` 为 `false`；
  仍在跑（新快照说 `true`）⇒ 仍为 `true`；`session.list` **读失败** ⇒ 保持原值（不知道就不撤）；
  `status` 帧单独一条（true 起 / false 收 + 清起点）。
  widget 级两条：`ChatPage` 重连后运行条消失、输入栏从「停止」回到「发送」；
  **只靠 `status` 帧**也能让运行条起落。
- `connector/tests/connection-scope.test.ts`：`sendStatus` 在未认证时**不发**、认证后推一封
  `status` 帧（载荷 `{running}`）。
- `connector/tests/frame-list-single-source.test.ts` 与 `job-frame.test.ts`：帧类型清单
  与契约 §3 **逐项相等**（加一种帧必须两侧同时改 —— 本轮就是这么发现契约表漏行的）。
- 真机（`d61cf622`，2026-10-22）：执行中 `shots-2026-10-22/g-213439.png`；
  `turn/end` 后 `i1-after-turn-end.png`（App 全程前台，未重启）。
  **W4 之后这条判据的数据源变了，真机尚未复验**（1 回合，见
  `.agents/notes/proposed/2026-10-24-running-from-native-status.md` 的"判据"一节）。
- 真机（`d61cf622`，2026-10-22）：执行中 `shots-2026-10-22/g-213439.png`；
  `turn/end` 后 `i1-after-turn-end.png`（App 全程前台，未重启）。
  重连这条边界**没有真机回合**：模型级 + widget 级用例已覆盖，见
  `.agents/notes/implemented/2026-10-23-running-rebuilt-on-reconnect.md`。

## 4. 有意不做

- **思考行（`_CollapsibleNote`）不扫光**：`ReasoningItem` 没有"还在流"的字段
  （`AssistantTurn.reasoning` 只是一段字符串）。硬加需要编一个状态，不比现在诚实。
- **转圈状态点（`StateDot`）不铺到工具行**：工具行已有的 `loading` 字形 + 扫光
  已经表达了"在跑"，再叠一个 14px 转圈环是同一件事说两遍。
- **鲸鱼尾 APNG**：见 §2（零新资源）。
