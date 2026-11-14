# Agent Note: Agent Teams 只读接入 —— 投影本来就到手机，「子会话看根板」不做

Status: implemented

## Problem

手机要显示共享任务板。动手前有四件事必须先核，**每一件都能改变实现形状**：
投影到底会不会自己到手机、`resolveAgent` 能不能拿到、`sid → Agent` 走哪条路、
以及子会话拿到的 `agentTeam` 是空还是缺席。

第四件核出了两条与直觉相反的结论，其中一条**推翻了本次委托里写下的验收标准**：

1. `agentTeam` 对**任何**会话都在（含子会话），子会话拿到的是**空板**
   （`enabled: false, tasks: []`），而不是「缺席」。真正的任务板只存在于**根会话**自己的日志里。
2. **DSH 自己的界面在子会话里既不显示任务板、也不显示开关**
   （`packages/client/ui-agent-team/src/client/TeamModeToggle.tsx:30-32`：
   `addressedChild || listedChild` ⇒ `return null`）。

于是「子会话里看到共享自根会话的只读事实」这条验收，要么照抄宿主（子会话没有这块板），
要么让连接器跨会话取数 —— 那是宿主客户端从不做的事。这条岔口先停下来问过，
答复是**照抄 DSH**，因此按 A 落地（见 Decision）。

## Decision

**只读版照抄宿主语义：投影直接解析，面板是右抽屉的一枚；子会话不给这枚 tab；
连接器只加一个能力位，不加方法。**

四条判据都可机械判定：

1. **数据不新开通道**：任务板读 `session.projections` 应答里的 `agentTeam`，连接器原样透传
   （`connector/src/dsh/projections.ts:68-72` 的 `valuesOf` 只拆信封、不挑键）。
2. **可见性只有一处**：`app/lib/ui/side_panel_visibility.dart` 的 `visibleSidePanels` ——
   `team` 这枚要求 `caps.team == true` **且** 当前会话是根会话；tab 条、计数徽标、面板主体
   三处都读它（`SidePane.panels`），所以"tab 在、主体空"不可能出现。
3. **能力位只看服务在不在**：`connector/src/dsh/caps.ts` 的 `readCaps` 里
   `team: present(ctx, 'agentTeams')`。Team **开没开**是投影的 `enabled`，不塌进能力位。
4. **宿主的三个判断手机不算**：`ready`（DAG 推导）、`writeScopeWarnings`、
   `ownerName ?? ownerId ?? 未分配`（`TeamBoard.tsx:46`）—— 全部照用，见
   `app/lib/model/team_board.dart` 的文件头。

## 事实核实

行号一律指 `dsh-v0.2.2-rc.3` 标签的树；"真宿主"指本机那台 0.2.2-rc.3 的装机。

### 1. 连接器透传确实不挑键 ⇒ `agentTeam` 自己出现在手机的 `values` 里

- 代码：`connector/src/dsh/projections.ts:68-72` 只取 `{kind, asOfSeq, values}` 里的 `values`，
  整个映射原样返回；文件头「为什么原样透传，不挑字段」写明不预知键名。**连接器这一侧零改动。**
- 真宿主证据（比源码硬）：`~/.dsh/storages/session_projcache/sessions/` 的 40 个样本里
  **13 个**含 `"agentTeam"`，其中一份是
  `"agentTeam": {"ver": 7, "seq": 665, "val": {"inheritedEventCount": 0, "id": "session-01c8470f-…",
  "tasks": [], "nextTaskNumber": 1, "enabled": true}}` —— 该投影在本机宿主上**已注册且在推进**，
  `enabled: true, tasks: []` 正是「Team 开着但没任务」那一档。
- 装机确认：`app.asar/dsh/node_modules/@deepseek-ai/dsh-base/package.json` 的 dependencies 里有
  `@deepseek-ai/dsh-agent-team@0.2.2-rc.3` 与 `@deepseek-ai/dsh-tool-agent-team@0.2.2-rc.3`，
  三个包（含 `dsh-client-ui-agent-team`）都真装在 `node_modules/@deepseek-ai/` 下。

### 2. `resolveAgent(sessionId)` 是谁暴露的、什么形状、我们能不能拿到

- `packages/api/session-controller/src/index.ts:271` 的 `resolveAgent(sessionId)` 是
  `SessionController` 的**公开方法，但没有 `@Remote`** —— 不在线上方法集里。
- 形状：`Promise<ApiSessionAgentResult>`，而 `ApiSessionAgentResult` =
  `{agent: Agent} | {error: ApiSessionAgentError}`（`packages/api/session-controller/src/agent.ts:89-91`）。
- 它**会 resume** 不在内存里的会话（`agent.ts:151-152` → `resolve()`：先查 live、再 attach、
  再 resume，并发去重）。`agents.get()` 不做这件事，两者语义不同。
- 我们能拿到：进程内持有 `sessionController` 即可调；但**这不是宿主自己走的路**（见下条）。

### 3. 从手机的 `sid` 到 live `Agent`：两条路都核过，**选 gateway remote**

- 进程内现状路径：`deps.sessionOf(sid)`（`connector/src/alias.ts`）→ `agents.get(dshSessionId)`
  （`connector/src/dsh/questions.ts:84-88`、`models.ts:133-138` 都是这个写法），声明在
  `packages/core/agent/src/index.ts:580`，**不 resume**。
- 现成管道：`connection.createPeer({principal:{kind:'owner'}})` +
  `connection.createSharedFetchHandler('/api')`（`connector/src/dsh/interaction-client.ts:285-286`
  已用它回 `$events/result`），同一条 fetch 可发任意宿主方法。
- 线上方法名与参数由 DSH 自己的 e2e 钉死：`agentTeams/setEnabled`，args 是 **`{agentId, enabled}`**
  （`packages/team/agent-team/tests/built-lib.e2e.ts:37-41`：`input.safeParse({ agentId: 'root', enabled })`
  通过、缺 `agentId` 被拒）。这条路上 `agent` 参数的解析走 `resolveAgent`
  （`agent.ts:128-132` 的 `ctx.typert.lookups.configure('agent', …)`），**自动带 resume 语义**。
- 宿主客户端调的就是它：`packages/client/ui-agent-team/src/client/mount.ts:43`
  `scope.remote.agentTeams.setEnabled(sessionId, enabled)`。

**为什么选这条**：`setEnabled` 要一个 live `Agent`，而"要不要为一个开关把不在内存里的会话拉起来"
是**宿主的决定**（Web 走 lookup 就 resume）。走进程内 `agents.get` 就轮到我们回答：要么自己调
`resolveAgent`（替宿主决定"把整个 agent 拉起来"），要么直接失败（用户点了没反应）。
前者替宿主做决定，后者砍掉宿主的能力 —— 两条都违反「宿主语义优先」。

### 4. 子会话是**空板**，不是缺席；根板只在根会话里

- `sessionProjections.snapshot()` 对**每一个**已注册且有 `wire` 的单元都写一格
  （`packages/session/session-projection/src/index.ts:514-526`，`:525` 就是 `values[key] = viewCell(…)`），
  所以只要有 Team 服务，**任何会话**（含子会话）的 `values` 里都有 `agentTeam`。
- 子会话拿到的值来自它自己的 init 状态 `emptyTeamState(header.id)`
  （`packages/team/agent-team/src/projection.ts:71-79`），线上视图是 `{enabled:false, tasks:[]}`
  （`TeamProjection` = `{enabled, tasks, failure?}`，`types.ts:98-102`）。
- 根板的 `team/mode` / `team/task` 只追加在**根会话**日志上（`agent-team/src/index.ts:116`），
  子会话自己的投影永远看不到。读取侧一律 `rootOf(caller)`（`index.ts:95-97`、`:113`），
  而 `subagents.rootOf(agent)` 是宿主侧公开方法（`packages/subagent/subagent/src/index.ts:300`），
  **要 live Agent**，拿不到就抛。

| 手机看到的 `agentTeam` | 含义 |
|---|---|
| 键缺席 | 这台电脑没有 Team 服务 |
| `{enabled: false, tasks: []}` | Team 关着，**或**当前是子会话（同形，分不出） |
| `{enabled: true, tasks: [...]}` | Team 开着，任务在下面 |
| 带 `failure` | 有一条持久记录读不进来；任务仍是上一版有效值（`projection.ts:190-196`） |

## 落地清单

| 面 | 改动 |
|---|---|
| 连接器 | `connector/src/dsh/caps.ts`：`OPTIONAL_SERVICES` 加 `agentTeams`；`Caps` 加 `team`；`readCaps` 里 `team: present(ctx, 'agentTeams')`。**不加方法** |
| 手机·解码 | 新增 `app/lib/model/team_board.dart`（值 + 解析）；`wire/rpc/projections.dart` 的 `_teamOf`（键名唯一入口 + 形状坏时计一次数）；`core/session_projections.dart` 加 `team` 字段 |
| 手机·能力位 | `core/repo_info.dart` 加 `teamAvailable`；`wire/rpc/repo.dart` 里 `caps['team'] == true`（与 `files`/`plugins` 同档，缺键按 false）；`data/app_model.dart` 暴露 `teamAvailable` 与 `teamBoard` |
| 手机·界面 | 新增 `ui/team_board_view.dart`（标题 + 进度短语 + 任务行 + 展开详情）；`ui/side_pane.dart` 加第四枚 `SidePanel.team` 与 `panels`/`teamBody`/`runningTeam`；新增 `ui/side_panel_visibility.dart`（可见性唯一判据）；`chat_page.dart` 接线 |
| 文档 | 新增 `docs/subsystems/agent-team.md`；`docs/AGENTS.md` 文档表加一行 |
| 用例 | `app/test/team_board_test.dart`（14 项：解析 / 回落 / 阻塞 / 失败 / 空板 / wire 入口）+ `app/test/team_panel_test.dart`（12 项：可见性三态 / tab / 回落 / 徽标 / 行与详情）+ `connector/tests/caps-team.test.ts`（3 项） |

**变异校验**（证明新断言不是恒真，各恰好红 1 条）：
① `visibleSidePanels` 去掉 `&& !childSession` ⇒ 只有「子会话 ⇒ 不出现」那条红；
② `TeamTask.ownerText` 去掉 `ownerId` 回落 ⇒ 只有「ownerName 缺席回落 ownerId」那条红。

## Alternatives considered

1. **B：子会话里显示根会话的任务板（只读、无开关）**
   - 最强的理由：用户在子会话里也想看"这棵树在干什么、卡在哪"；服务层本来就支持
     （`getTask/listTasks(caller)` 内部一律 `rootOf(caller)`），数据是现成的；而且这正是
     本次委托原本写的验收标准第 2 条。
   - 为何被否：它要求连接器**跨会话**取数（`agents.get(子会话)` → `subagents.rootOf()` →
     用根会话 id 再读一次投影）。`rootOf` 要 live Agent，子会话没在内存里就抛 —— 于是
     要么替宿主决定"拉起一个 agent"，要么让手机对着一个会失败的读取点。而宿主自己的客户端
     **从不**这么做：它在子会话里把整块藏掉。取舍由委托方拍板："先抄 DSH 自己的"。
2. **把"有没有 Team"与"Team 开没开"合成一个能力位**
   - 最强的理由：手机侧少一个字段，判断更简单。
   - 为何被否：两者会打架 —— 服务在、开关关着时能力位若是 false，界面会说"这台电脑不支持"，
     而真相是"支持但没开"。而若能力位跟着 `enabled` 走，那它就变成会话级事实，与 tab 的
     存在性（进程级）混为一谈，切会话时 tab 会莫名闪。
3. **连接器新增 `team.list` 之类的方法**
   - 最强的理由：把"读任务板"变成一条明确的契约，手机侧不用理解投影。
   - 为何被否：投影已经原样到手机（`values` 里就有），再开一个方法等于把 DSH 已有的投影面
     翻译一遍 —— 翻译层就是漂移层（`connector/src/dsh/projections.ts` 文件头同一条）。
   - 附注：这一条在**写入**（阶段 C）不成立 —— 那时必须新增方法，且要从 `METHODS` 走。

## Consequences

- 收益：**读路径零新增契约** —— 连接器只多一个 bool，方法数不变（仍 52），
  手机拿到的投影本来就含 `agentTeam`。真宿主证据在手，不是推的。
- 收益：`sid → Agent` 的走法被定成 gateway remote，理由是"把 resume 的判断交还宿主"，
  这条同时给阶段 C 的写方法定了形（`agentTeams/setEnabled` + `{agentId, enabled}`）。
- 收益：可见性判据只有一处（`visibleSidePanels`），tab / 徽标 / 主体不可能各说各话；
  三态（老宿主 / 子会话 / 根会话）各有一条用例。
- 代价：**子会话看不到共享任务板**。这是照抄宿主，但与"在子会话里也能看到全局"的直觉相反；
  根会话是唯一入口。
- 代价：`side_pane.dart` 从 950 长到 982、`app_model.dart` 从 5150 长到 5167，
  两处预算表都按规矩抬了数字并写明理由（`app/tools/verify-size.mjs`）——
  可见性规则搬到 `ui/side_panel_visibility.dart` 是为了不让这个文件继续膨胀。
- 代价：`caps.team` 与投影的 `enabled` 是两个判据，手机侧必须都读；少读一个的症状分别是
  "老宿主上出现一块空板" / "Team 开着却只画一块空白面板"。
- 未做：**写入**（开关）。只有根会话能调 `setEnabled`，且要进 `connector/src/protocol/methods.ts`
  的封闭方法集并同步契约文档 —— 那是阶段 C。
