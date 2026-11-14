# 下一轮提示词：DSH 0.2.2-rc.3 体检 + 智能体团队（Agent Teams）接入

> 用法：新会话第一句整段复制粘贴（或说「读 `.agents/notes/proposed/2026-11-14-next-round-agent-team.md` 并按它执行」）。
> **这一轮要写代码**，但顺序是：先核源码 → 再定设计（落笔记）→ 再实现。方案不成立就**停下来回报**，不要自己换个方向继续。
> 上一轮已提交：`14d0055`（连接方式三层 + 面板收窄 + 通知收敛），工作区干净。

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh，中文回复）。
Flutter App + TS 连接器（connector/，pnpm 工程）+ Node 中转（relay/）+ 可执行协议（protocol/）。
DSH 参考源码（**只读，不许改**）：D:\sudy\github\deepseek-harness，当前 0.2.2-rc.3。

## 0. 先读（按顺序，别跳）

1. `AGENTS.md` —— 铁律。这一轮特别吃紧的三条：
   - **引用 DSH 行为必须给 `packages/...:行号`；查不到就写「未找到」，禁止猜。**
   - 非平凡改动必须留决策笔记（`decision-notes` 技能），代码与笔记同批提交。
   - 改源码只用编辑工具，不用 shell 字符串替换。
2. `memory.md` —— 现状快照（末尾是本轮之前的连接方式改动）。
3. `tools.md` —— 门禁命令与**断言条数的唯一出处**。§「隔离实例」那条是真机路径（含五个坑）。
4. `.agents/notes/implemented/2026-11-13-connection-route-model.md` —— 上一轮同类工作的形状：
   它是怎么把「能力 / 策略 / 当前」拆开、怎么写出可机械判定的门槛的。这一轮照这个体例写。

## 1. 这一轮要做什么（三阶段，每阶段做完回报一次）

### 阶段 A（先做，纯核对，不改行为）：DSH 0.2.2-rc.3 体检

我们 pin 在 `0.2.2-rc.1`（`connector/package.json` 的 devDependencies + `engines.dsh`
`>=0.2.2-rc.1 <0.2.3-0`，rc.3 在范围内）。npm `@deepseek-ai/dsh-base` 的 `next` 已是 `0.2.2-rc.3`。

做三件事，产出一篇笔记 `implemented/<日期>-dsh-022-rc3-audit.md`：

1. **服务键 / 方法 / 事件逐项核**（照 `implemented/2026-11-12-dsh-022-rc2-audit.md` 的表格体例）。
   我们依赖的服务键在 `connector/src/dsh/caps.ts`（`REQUIRED` / `OPTIONAL` / `Caps`，见 `:115`）。
2. **`session.projections` 的键集合**有没有增删（我们原样透传，见 `connector/src/dsh/projections.ts`
   文件头：不挑字段、拆掉 `{kind, asOfSeq, values}` 信封）。
3. **rc.2 的 13 个 breaking topic 逐条判**「影响/不影响 + 依据」。
   清单在 `docs/upgrade-guide/v0.2.2-rc.2/`（每个主题一个目录，读 `guide.zh.md`）。
   与插件作者最可能相关的四条先看：`package-export-cleanup`、`session-status-package`、
   `cordis-root-and-intercept-metadata`、`client-module-metadata`。
   **注意**：rc.3 没有自己的 upgrade-guide 目录（`docs/upgrade-guide/` 最新是 `v0.2.2-rc.2`），
   所以 rc.2→rc.3 的差异要用 `git log`/`git diff` 两个 tag 去核，别假设"没有 guide 就没变更"。

判完再决定要不要把 `connector/package.json` 的 devDeps 抬到 rc.3。
**抬类型基线会掩盖运行期问题**（`memory.md` 有这条），所以：先体检、再抬、抬完必须重跑全量 connector 测试。

### 阶段 B：Agent Teams 的**只读**接入（手机端能看到任务板）

#### B.0 背景：Team 是什么（先读这几处，别凭这段描述就动手）

已核实的事实（我核过，但**你要按行号自己再看一遍**）：

- Team **不是新的智能体类型**，是给已有子智能体树加一块共享任务板。
  `packages/team/README.md` 的 Summary 明写：*"The Team packages let agents in a subagent tree
  share task ownership and dependencies… Subagent creation, discovery, messaging, and interruption
  remain in the subagent package family."*
- 服务：`packages/team/agent-team/src/index.ts:46` `class TeamService extends TypertRemoteService`，
  ctx 键 `agentTeams`。
- **开关是一个 @Remote 方法**：`packages/team/agent-team/src/index.ts:111-112`
  `@Remote async setEnabled(agent: Agent, enabled: boolean, signal?: AbortSignal): Promise<void>`。
  配置项 `defaultEnabled` 默认 false（`:51`、`:71`）；`maxTasks` 默认 256。
- **投影键是 `agentTeam`**：`packages/team/agent-team/src/projection.ts:207-214`
  （`key: 'agentTeam'`，`wire.viewSchema` = `teamProjectionSchema`）。
  wire 形状见 `docs/subsystems/agent-team.md` §Web projection 的两个 ```ts type-equiv``` 块：
  `TeamProjection = { enabled: boolean; tasks: TeamTaskView[]; failure?: string }`，
  `TeamTaskView = { id, revision, subject, description, status, blockedBy[], writeScopes[],
  ownerId?, ownerName?, ready, writeScopeWarnings[] }`。
- **标准 bundle 已带它**：`packages/bundle/base/package.json:45`（`dsh-agent-team`）与 `:110`
  （`dsh-tool-agent-team`）。所以用户装的是标准包就已经有，只是默认关。
- **只有根会话能 `setEnabled`**，后代共享它的档位；`team/mode` 记录显式选择；
  历史任务板在没有显式选择时**视为开**（见 `docs/subsystems/agent-team.md` §Web projection）。

#### B.1 先验证这条链（**第一件要做的事，做完立刻回报**）

我们要让手机能读任务板、能开关。读靠投影（**连接器大概率一行不用改**），写要新方法。

**必须先核实、不许猜的四点**：

1. `connector/src/dsh/projections.ts` 的透传是否真的不挑键 —— 若是，
   `agentTeam` 会**自动**出现在手机拿到的 `values` 里。核实方式：读该文件 + 跑一次真宿主
   （隔离实例）`session.projections`，看返回值里有没有 `agentTeam` 键。
2. `packages/api/session-controller/src/index.ts:272` 的 `resolveAgent(sessionId)` 是谁暴露的、
   返回什么形状、我们能不能拿到（我们的会话面适配器在 `connector/src/dsh/sessions.ts`）。
3. `TeamService.setEnabled` 要一个 **live `Agent` 句柄**。确认我们这一侧怎么从手机的 `sid`
   拿到 DSH 会话 id、再拿到 Agent；拿不到就走 gateway remote（我们已有 `typertGateway` 服务，
   见 `caps.ts` 的 OPTIONAL 清单），**两条路都核过再选**，并在笔记里写明为什么选这条。
4. 子会话拿到的是**空**还是**缺席**（投影由根会话发布）。手机侧解析要能区分「没有 Team」
   与「Team 开着但没任务」。

把这四点写进笔记的 `## Problem` 之前的「事实核实」小节，每条带 `packages/...:行号`。
**核不出结论就停下回报**，不要先写代码。

#### B.2 实现（只读版）

- **手机端**：`app/lib/data/projection.dart` 解析 `agentTeam`。
  界面**不是新页**：右抽屉的面板是 `enum SidePanel`（`app/lib/ui/side_pane.dart:70`），
  tab 条在 `:345` 按 `SidePanel.values` 渲染、计数徽标也按面板分支（`:349-351`）——
  所以"加一块任务板"= **加一个 enum 值 + 一个 body 分支 + 徽标判据**，tab、语义、计数自然跟上。
  行规格照 `app/lib/ui/subagent_tree.dart` 的密度；任务状态映射照 `TeamTaskStatus` 的**字面值**
  （自己从源码取，不要从文档抄）。
- **能力位**：`connector/src/dsh/caps.ts` 加 `team`（判据 = `agentTeams` 服务在不在）。
  老宿主没有该键 ⇒ false ⇒ 手机不显示这枚 tab（不是显示空板）。
- 契约与文档：`docs/subsystems/` 加一节；`docs/subsystems/ui-state.md` 只在真的新增设备键时才改。

#### B.3 验收（可机械判定）

1. 手机上根会话打开右抽屉，能看到「任务」这枚面板 tab 并列出任务（宿主里先造两条任务，带依赖关系）。
2. 子会话里看到的是"共享自根会话"的只读事实，**不许**给一个点了会失败的按钮。
3. 服务缺失（老宿主 / 没挂工具包）⇒ `caps.team=false` ⇒ 这枚 tab 整枚不显示，不掉空态。
4. 单测：投影解析（含 `failure`、含 `ownerName` 缺席时的回落）、caps 判定、tab 可见性三态。

### 阶段 C：开关写入（只在 B 完成后做）

- 连接器加写方法（`connector/src/protocol/methods.ts` 的 **封闭方法集** + `connector/src/handlers.ts`）。
  注意：方法名一旦进 `METHODS` 就要在契约文档里有一行，否则下一轮会把它当"契约外"清掉
  （该文件头写明了这条历史）。
- 手机端：**只有根会话**显示「启用智能体团队协作」开关，位置与模型选择器同组。
  子会话不显示（`setEnabled` 只有根能调）。
- 验收：开 → 宿主侧真的写了 `team/mode`（去 DSH 侧核，不要只看开关变了）；
  关 → 工具从后续步骤消失但任务与子智能体都还在（这是 DSH 的承诺，验一遍）。

## 2. 现在就要遵守的三条硬规则

1. **一切 DSH 断言带行号**。`docs/subsystems/agent-team.md` 里 `<!-- BEGIN GENERATED cordis-surface -->`
   到结尾那段是源码生成的（`scripts/gen-cordis-catalog.ts`），可信；但**README 与 guide 是人写的，
   可能与源码漂移** —— 用来理解意图，动手前回源码核。
2. **不要从文档抄 wire 形状**。形状以 `projection.ts` 的 zod schema（`:86-93`、`:166-170`）
   与 `client/` 侧的消费为准。抄错一个字段名，手机端会静默显示空板。
3. **不新增宿主没有的边界**。不要给 Team 加超时、重试、去重、"谁接管"之类的东西 ——
   DSH 没这些语义（`AGENTS.md` 的「宿主语义优先」）。

## 3. 门禁（条数以 `tools.md` 为准，别信任何笔记里抄的数字）

```pwsh
cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test
cd ..\app; dart format --output=none --set-exit-if-changed lib test; dart analyze --fatal-infos lib test; flutter test
cd ..; node app/tools/verify-platform-boundary.mjs; node app/tools/verify-size.mjs
```

- **`flutter test` 单测 60 秒超时上限**（`AGENTS.md`）。
- 动了 `app/lib/` 必须跑 boundary + size（size 是棘轮：**只降不升**，长了要在表里写明理由）。
- 动了 `protocol/` 三条 `node protocol/verify-*.mjs` 必须全绿。
- 真机可选：`tools.md` §「隔离实例」那条（`D:\tmp\dsh-mobile-home` + `--profile dsh-mobile-test`，
  中转 `node relay/src/main.ts --config relay.config.json`，实例 `dsh --profile dsh-mobile-test --port 3099 --no-open`）。
  **注意**该实例里有一条 `extra` 上报地址（`ws://192.168.2.41:18791`），是本机双网卡用的，别当成 bug。

## 4. 已定的设计决策（不要再论证）

- **任务板做成右抽屉的 `SidePanel` 一枚**（与子智能体 / 任务 / 文件并列），不新开顶层页：
  任务板是**根会话级**的，子智能体目录本来就是那棵树 —— 两者放一起用户才理解"谁在干什么、卡在哪"；
  而 `SidePanel` 的 tab 条与计数徽标是数据驱动的（`side_pane.dart:345-351`），加一枚成本最低。
- **只读先上，开关后做**：投影已经自动到，只读版的爆炸半径最小。
- **Team 不隔离工作目录**（官方 Known Limitations：no worktree / no merge / no filesystem lock），
  所以手机上"两条任务改同一文件"只能是**告警**，不许写成保证。

## 5. 不要做的事

- 不要给 Team 加 `maxMembers` / 消息大小 / 回收超时这类配置 —— 那些键**已被删除**，
  设了插件不激活（`agent-team/README.md` 的配置表下方明写）。
- 不要把 Team 和 `subagentCatalog` 合并成一个投影（两个键、两个发布者）。
- 不要在手机端自己算 `ready` —— 投影里带着，照用（`ready` 是 DAG 推导结果，见 `projection.ts`）。
- 不要在连接器里"顺手统一" `relay/` 与 `connector/` 的导入风格（两者运行时不同，`tools.md` 有）。
```

## 事实核实台账（供新会话对照，不许当作结论）

| 断言 | 出处（我核过的行号） | 状态 |
|---|---|---|
| Team 只加共享任务板，成员仍是子智能体 | `packages/team/README.md` Summary | 已核 |
| `TeamService` / ctx 键 `agentTeams` | `packages/team/agent-team/src/index.ts:46` | 已核 |
| `setEnabled` 是 `@Remote`，签名要 live `Agent` | 同上 `:111-112` | 已核 |
| `defaultEnabled` 默认 false、`maxTasks` 256 | 同上 `:51`、`:71` | 已核 |
| 投影键 `agentTeam` | `packages/team/agent-team/src/projection.ts:207-214` | 已核 |
| 标准 base bundle 已带两个 Team 包 | `packages/bundle/base/package.json:45`、`:110` | 已核 |
| `resolveAgent(sessionId)` 在 session-controller | `packages/api/session-controller/src/index.ts:272` | 已核（**形状未核**） |
| `@Remote('projections')` 拆信封 | 同上 `:622` + 我们 `connector/src/dsh/projections.ts` 文件头 | 已核 |
| 手机侧 caps 结构与 `Caps` 接口 | `connector/src/dsh/caps.ts:115` | 已核 |
| rc.2 有 13 个 breaking topic | `docs/upgrade-guide/v0.2.2-rc.2/` 目录 | 已核（**内容未逐条判**） |
| rc.3 无独立 upgrade-guide | `docs/upgrade-guide/` 最新目录是 `v0.2.2-rc.2` | 已核 |
| npm `next` = 0.2.2-rc.3 | `npm view @deepseek-ai/dsh-base dist-tags` | 已核 |
| 我们 pin 在 rc.1 | `connector/package.json` devDeps + `engines.dsh` | 已核 |

「已核（形状未核）」「内容未逐条判」这两行就是阶段 A/B.1 的活。
