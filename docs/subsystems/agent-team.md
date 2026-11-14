# 共享任务板（Agent Teams，只读）

右抽屉的一枚面板：显示**根会话**那一块 Agent Teams 共享任务板。数据来自宿主的
`agentTeam` 投影，连接器原样透传 —— 这一面**没有自己的方法**。

## 1. 数据来源与形状

唯一来源是 `session.projections` 应答里的 `agentTeam` 键。它的 wire 形状由宿主那两个
`.strict()` 的 zod schema 定死（多一个字段都非法）：

| 层 | 形状 | 出处 |
|---|---|---|
| 板 | `{enabled: boolean, tasks: TeamTaskView[], failure?: string}` | `packages/team/agent-team/src/projection.ts:185-190` |
| 任务 | `{id, revision, subject, description, status, blockedBy[], writeScopes[], ownerId?, ownerName?, ready, writeScopeWarnings[]}` | 同文件 `:154-168` |
| `status` 字面值 | `'pending' \| 'in_progress' \| 'completed' \| 'deleted'` | `packages/team/agent-team/src/types.ts:61` |

手机侧解码在 `app/lib/model/team_board.dart`（值类型）与 `app/lib/wire/rpc/projections.dart`
（键名唯一入口，`values['agentTeam']`）。**不要另抄一份形状到别处**。

`deleted` 在线上已被宿主滤掉（`projection.ts:182`）；手机再滤一次（`visibleTasks`）只是为了
"万一出现也不显示"。状态字面值认不出的任务**整条丢掉**，不降级成 `pending`。

## 2. 三样东西是宿主的判断，手机不算

| 字段 | 谁算的 | 手机怎么用 |
|---|---|---|
| `ready` | 宿主按 `blockedBy` 做 DAG 推导（`task-view.ts`） | 只读。被阻塞 = `status == 'pending' && !ready` |
| `writeScopeWarnings` | 宿主算好的写作用域冲突告警（`task-view.ts:35-42`） | 原样显示，不做第二判断 |
| `ownerName` | 分配时抓的 agent 路径；历史数据可能没有（`projection.ts:203-207`） | 回落链 `ownerName ?? ownerId ?? 未分配`（`TeamBoard.tsx:46`） |

**Team 不隔离工作目录**（官方 Known Limitations：no worktree / no merge / no filesystem lock），
所以"两条任务改同一文件"只能是一句**告警**，不是保证。

## 3. 什么时候出现

`visibleSidePanels`（`app/lib/ui/side_pane.dart`）一处判定，tab 条 / 徽标 / 主体都读它：

1. **`caps.team == true`** —— 电脑侧有 `agentTeams` 服务（`connector/src/dsh/caps.ts` 的
   `readCaps`）。老宿主 / 没带 tool bundle 的部署 ⇒ 整枚 tab 不出现（不是显示一块空板）。
2. **当前会话是根会话** —— 子会话照 DSH 连开关带任务板一起不显示
   （`ui-agent-team/src/client/TeamModeToggle.tsx:30-32` 对子会话 `return null`；
   `ui-agent-team/README.zh.md:28`："子会话保留子智能体导航，不显示任务板或 Team 开关"）。

`caps.team` 只回答"这台电脑有没有这个服务"。**"Team 开没开"是投影的 `enabled` 字段**，
两件事不能塌成一个能力位。

## 4. 子会话的投影是空板，不是缺席

投影对**每个会话**都有 `agentTeam` 一格（`session-projection/src/index.ts:514-526`），
而 `team/mode` / `team/task` 事件只追加在根会话日志上（`agent-team/src/index.ts:116`）。
所以子会话拿到的是 `{enabled: false, tasks: []}` —— 与"根会话没开 Team"**同形**，
从投影里分不出"这是子会话"。判是不是子会话看会话行的 `subagent` 标志，不看这个键。

| 看到的 `agentTeam` | 含义 |
|---|---|
| 键缺席 | 这台电脑没有 Team 服务（老宿主） |
| `{enabled: false, tasks: []}` | Team 关着，**或**当前是子会话 |
| `{enabled: true, tasks: [...]}` | Team 开着，任务在下面 |
| 带 `failure` | 有一条持久记录读不进来；任务仍是**上一版有效值**（`projection.ts:190-196`） |

## 5. 界面规格

- 标题行：`[清单图标] 共享任务` + 进度短语 `{n} 已完成 · {n} 进行中 · {n} 待处理`
  （零的段不出现；分隔符 `\u2002·\u2002`，逐字照 `TeamBoard.tsx:41-47`）。
- 任务行（`app/lib/ui/team_board_view.dart`）：`[状态点] 标题 [箭头]`，密度照
  `ui/subagent_tree.dart`（上下各 6）。点一行展开说明、负责人、写作用域告警。
- 状态点：`pending → idle`、`in_progress → ongoing`、`completed → done`；
  **被依赖阻塞时画琥珀 `warning`**（`TeamBoard.tsx:36-40,59-61`）。
- tab 徽标 = **进行中**的任务数（与另外两枚"在跑的才计数"同一条），0 时不显示。
- 文案逐字取自 `ui-agent-team/src/client/locales.ts` 的 zh 字典；**没有自创措辞**。

## 6. 边界

- **只读**：这一面不写任何宿主状态，没有开关、没有建/改/删任务的入口。
  写入（`agentTeams/setEnabled`，线上参数 `{agentId, enabled}`）属于另一批工作。
- `failure` 原样显示成「任务记录无效：…」，**不翻译成"加载失败"** —— 那时任务板本身仍可用。
- 手机不展示 `blockedBy` 的图形化依赖（宿主只给 id 列表，画成图需要另一套语义），
  被阻塞只体现为那个琥珀点。
