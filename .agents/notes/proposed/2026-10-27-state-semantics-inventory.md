# 状态语义缺口清单（UI 状态：谁拥有、记不记、约束在不在）

- 日期：2026-10-27
- 状态：proposed。**2026-10-27 已审计完**：归属表与桌面/移动端证据见
  `2026-10-27-state-semantics-audit.md`，机制原则见 `2026-10-27-state-semantics-mechanism-decisions.md`。
  本文件只保留"缺口清单"的原始形态；其中第 2/3/4/5 条的口径已被审计表 §C 更正（以源码为准）
- 相关：`implemented/2026-10-26-connect-landing.md`、`implemented/2026-10-26-drawer-pickers-and-hero.md`

## 一句话问题

手机侧把桌面的**外观**复刻了，但桌面里的**状态语义**（哪些状态要记、哪些约束必须一致、连接瞬间的复合状态）
没有对齐：很多状态住在 widget 局部变量里，一关抽屉 / 一重进页面就丢；发送等动作也缺少桌面那些前置约束。

## 不变量（这一批要建立的）

1. **状态有唯一主人**：每个可见状态必须能回答"主人是谁"——
   `host`（电脑侧投影/接口）、`browser-local-but-persisted`（桌面自己持久化在浏览器存储）、
   或 `device-local`（手机本地偏好）。**不允许"住在 widget 里"这种第四种主人**。
2. **桌面对某动作有前置约束的，手机必须同样约束**（例如未选模型/工作区时发送键不可用），
   不允许"能点但失败"。
3. **连接瞬间的复合状态必须一次画全**：桌面此刻显示什么（运行中、子代理后台任务、待处理项、
   计数角标），手机连上后应当得到同一组可见事实，而不是"点进某个页面才看得到"。

## 已发现缺口（每条都给证据）

| # | 状态/动作 | 桌面 | 手机现状 |
|---|---|---|---|
| 1 | 抽屉里工作区的折叠态 | 持久化："Explicit persisted group expansion"（`packages/client/ui-workspace/src/client/rows/WorkspaceBrowser.tsx:279-281`），store 带 `persist` | `app/lib/ui/session_drawer.dart` 的 `_expanded` 是 **widget 局部态**，关抽屉即丢 |
| 2 | 模型选择（新会话的默认） | 桌面新会话显示"之前选的那一档"；默认值住在 `agent-default-model`（本仓测试 profile 用 `cordis.patch.yml` 里 `- id: agent-default-model` 补丁，说明它是宿主服务） | 只读会话投影；新会话无投影 ⇒ 「请选择模型」 |
| 3 | 推理等级（思考程度） | 与模型选择同一个 `ModelSelection`（含 `reasoningEffort`），随模型记忆 | 同上：无投影时没有默认值；且"思考"chip 之前根本没接线（已修） |
| 4 | 新建会话时的工作区 | 桌面记住上次选的工作区；不选时用当前工作区 | 每次都落到 DSH 当前工作区，不记用户上次选择 |
| 5 | 发送前置约束 | `primaryDisabled = empty \| disabled \| machineBusy \| uploadsPending`（`packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:343`），未选模型/工作区时发送键不可用 | `canSend` 只看"有会话 + 有正文"；真机上出现"空白会话直接发 → 失败" |
| 6 | 会话草稿与视图选择（对话/轨迹） | 按会话持久化：`defineStore({ …, persist: CONVERSATION_STORE_KEY })`（`packages/client/ui-conversation/src/client/stores.ts:16-33`） | 草稿 `DshComposer` 局部态、`_tab` 页面局部态；重启即丢 |
| 7 | 连接瞬间的复合状态（运行中 + 子智能体后台任务） | 会话页直接呈现：运行态、子代理行内活动、任务计数角标 | 落在在跑会话 ✅；子代理后台任务**不在会话页呈现**，要进子智能体页/任务面板才看得到 |

（其余候选，待审计确认：轮组折叠态、侧栏开合、文件面板页签、`@` 候选 drill 记忆、输入焦点恢复。）

## 为什么不能逐条打补丁

这七条背后是同一个结构问题：**没有一个"UI 状态该住哪"的归属模型**。逐条加 `prefs.write` 会：
- 每个状态各自发明键名与序列化方式（第二份真值）；
- 忘记"宿主已经有的默认值"（模型/权限/工作区都是宿主服务，不该在手机再存一份）；
- 发送门槛这类"约束"没有唯一落点，下次新动作继续漏。

## 验收口径（这一批做成什么样算完）

1. 一张**状态归属表**：每个可见状态 → 主人（host / browser-local-persisted / device-local）→ 持久化键 → 读取时机。
2. **一处机制**：设备本地状态统一走一个 `UiStateStore`（一个键前缀、一处序列化、一处恢复），
   widget 不许再持有"跨页面/跨重启该活下来"的状态。
3. **约束集中**：发送等动作的可用性由**一个**函数决定（缺什么就返回缺什么），UI 只消费结论。
4. **连接时的复合状态**：一次 `session.list` + 相关投影就画全（运行中、子代理后台任务、计数），
   与桌面同一组事实。
5. 每条都有红先的用例；真机上逐条截图；`docs/` 只写现状事实，取舍回指本清单与新笔记。
