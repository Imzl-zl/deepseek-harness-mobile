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

## 3. "在跑吗"判据：事件流，不是 `session.list`

`AppModel.runningOf(sid)` = `turn/start` 之后还没等到 `turn/end`（`_runningSids`）——
事件本身就是电脑侧事实，而且实时。**这是唯一真值**：`session.list` 的 `running`
只在读到的那一刻往 `_runningSids` 里**补一笔**（打开会话时还没有事件，那一笔是初值），
**不许撤销** —— 撤销只由 `turn/end` 做。反过来（用快照 OR 事件）会让旧快照的
`true` 永远关不掉：2026-10-22 真机上一轮结束后仍转了 5 分钟，杀 App 才消失。

三处读同一个真值：运行条（`_ConversationFlow.running`）、输入栏的「排队发送」与
「工作步骤展示」的运行中展开（`chat_page.dart` 的 `_running`）、子智能体行的状态。

`turnStartedAtOf(sid)` 读 `_turnStartedAt`（`turn/start` 的 `time`），兜底读
`trajectory.runningTurn.startTime`（**只对当前会话**）。

**为什么不只用 `session.list` 的 `running`**：那张表只在连上 / 收口 / 打开面板时重读，
轮次进行中是旧值；真机实测一轮跑了 40 秒、运行条整轮没出现。

## 3.1 判据

- `app/test/shimmer_test.dart`：`turn/start` 起 / `turn/end` 收；**快照说在跑时
  `turn/end` 也必须能停**（那条走真 `session.list` 解析器）。
- 真机（`d61cf622`，2026-10-22）：执行中 `shots-2026-10-22/g-213439.png`；
  `turn/end` 后 `i1-after-turn-end.png`（App 全程前台，未重启）。

## 4. 有意不做

- **思考行（`_CollapsibleNote`）不扫光**：`ReasoningItem` 没有"还在流"的字段
  （`AssistantTurn.reasoning` 只是一段字符串）。硬加需要编一个状态，不比现在诚实。
- **转圈状态点（`StateDot`）不铺到工具行**：工具行已有的 `loading` 字形 + 扫光
  已经表达了"在跑"，再叠一个 14px 转圈环是同一件事说两遍。
- **鲸鱼尾 APNG**：见 §2（零新资源）。
