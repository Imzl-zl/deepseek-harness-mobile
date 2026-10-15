# Agent Note: 手机端能显示 DSH 的哪些面 —— 一扇投影门 + 一张全覆盖清单

Status: proposed

## Problem

用户的要求是"DSH Web 上有的，看看哪些能在手机上显示"。逐个 `ui-*` 包去问
"这个能不能接"会问出 53 个问题，而其中大部分共享同一个答案 —— 所以先找那把钥匙。

## Decision

**钥匙是 `@Remote('projections')`。** 已核实
`packages/api/session-controller/src/index.ts:506`：

```ts
@Remote('projections')
async projections(request: SessionProjectionsRequest, signal): Promise<SessionProjectionsValue>
```

`SessionProjectionsRequest` **只有一个字段 `sessionId`**（`types.ts:423-425`），
返回值是**所有已注册投影的当前值**（`SessionProjectionValues`）。
也就是说：**一个方法，一把钥匙，打开几乎全部只读面。**

已核实的投影键（`ctx.sessionProjections.register({key})` 全仓扫描，178 处里与
"界面上看得见的东西"相关的）：

| 投影键 | 对应 Web 面 |
|---|---|
| `modelSelection` | 模型 chip（**已接**） |
| `permissions` / `sandboxMode` | 权限档（§7.10 那一屏） |
| `subagentCatalog` / `subagent` / `subagentTiming` | **子智能体树** |
| `deliverables` | **diff / 交付物** |
| `tokenUsage` / `contextPressure` / `contextBreakdown` / `sessionStats` | 统计条 |
| `turnOutline` | 轨迹页 |
| `todos` / `todo` | 待办清单 |
| `goal` | 目标 |
| `plan` | 计划模式 |
| `inbox` | 控制队列 |
| `title` / `titleInput` | 会话标题 |
| `workingDirectory` | 工作区路径 |
| `agentPreset` / `agentTeam` | 预设 / 团队 |
| `userQuestions` | 提问（**已接**） |

**这把钥匙推翻了上一轮的一个错结论**：我曾写"子智能体本期做不了"，
依据是 `subagents.listChildren` / `listDescendants` 没有 `@Remote`
（`subagent/src/index.ts:374,393`，已核实）。那是**找错了门**：
`SubagentRuntime` 本身就是 `TypertRemoteService`（`:192`），
但只有 `prompt` / `interruptByParent` 标了 `@Remote`（`:445,:512`）——
而**读面在投影里**（`subagentCatalog`，`catalog.ts:122`）。
顺带一个 Bonus：`@Remote('prompt')` 与 `@Remote('interruptByParent')`
意味着手机**不只读，还能给子智能体发消息和打断它**。

### 全覆盖清单（53 个 `ui-*` 按"手机上该不该有"分四类）

**A 类 —— 一个方法就能读，优先做**

| Web 面 | 钥匙 | 手机上的样子 |
|---|---|---|
| 统计条（`ui-session`） | `tokenUsage` / `contextPressure` / `sessionStats` | 底部三条真实数字（**现在是写死的 `302K · 缓存 0%`**） |
| 轨迹（`ui-trajectory`） | `turnOutline` | 甘特 + 账本真数据（**现在是 `_sampleEntries`**） |
| 子智能体（`ui-subagent`） | `subagentCatalog` | 侧抽屉第三个面板（**现在是 `_previewSubs`**） |
| diff / 交付物（`ui-deliverables`） | `deliverables` | 侧抽屉文件面板（**现在是 diff 预览的占位**） |
| 待办（`tool-todo` 投影） | `todos` | 新面板或并入轨迹 |
| 目标 / 计划（`ui-goal` / `ui-plan`） | `goal` / `plan` | 只读横幅 |

**B 类 —— 有独立 `@Remote`，要各自接**

| Web 面 | 依据 |
|---|---|
| 文件树 / 读文件（`ui-sidebar-files`） | `workspace-files` 的 `@Remote read/readBytes/stat/list/changes`（`api/workspace-files/src/index.ts:232,256,289,302,339`） |
| 模型目录（`ui-model-selection` / `ui-settings-models`） | `llm` 的 `@Remote listProviders()`（`llm/src/index.ts:470`）+ `@Remote listConfigurableProviders()`（`:542`）—— 比现在手抄的四个模型名更全 |
| 工作区列表（`ui-workspace`） | `workspace-controller` 的 `@Remote pick/list/create/…`（`api/workspace-controller/src/index.ts`） |
| 设置（`ui-settings*` 九个包） | `settings-controller` 的 `describe/update/replace/mutate`（`api/settings-controller/src/index.ts:97,115,132,151,166`） |
| 终端（`ui-sidebar-terminal`） | `terminal-controller` 的十个方法 + 两个 `@Remote({mode:'stream'})`（`api/terminal-controller/src/index.ts`） |
| 账号（`ui-settings-account`） | `account-controller` 的 `getState/getProfile/getBalance/…` |

**C 类 —— 手机上不做（形态不适合，或做了是负担）**

| Web 面 | 为何不做 |
|---|---|
| `ui-chat` / `ui-conversation` / `ui-renderer` 的完整桌面形态 | 手机已有自己的聊天页（§7.2 三条硬规则），照搬桌面是"缩小版桌面" |
| `ui-directory-picker-*` / `ui-open-in-app` | 唤起电脑上的编辑器，手机上没有对应物 |
| `ui-plugin-manager` / `ui-settings-plugins` | 插件管理是电脑侧操作（`plugin-and-jobs-notes.md` 已定"不做逐插件页面适配"） |
| `ui-sidebar-browser` / `ui-sidebar-documentpreview` | 内嵌浏览器 / Office 预览，手机上交给系统 |
| `ui-shortcuts` / `ui-dockkit` / `ui-layout` | 桌面键鼠与窗口管理 |
| `ui-workflow-run` / `ui-schedule` / `ui-skill` | 本期范围外（`memory.md` 的范围决定） |
| `experimental/*`（语音、CoT、agent-team） | 实验性，且多数要原生能力 |

**D 类 —— 阻塞：DSH 侧没有出口**

只有一个：**`ui-subagent` 的写面**。`@Remote('prompt')` 与
`@Remote('interruptByParent')` 已核实存在，所以**不阻塞**；
真正没出口的是 `subagent/descriptor` 之类的事件追加，而手机不需要写它。

> 结论：**没有一个面是"DSH 完全没给路"的**。上一轮我把子智能体判成阻塞，
> 是因为只看了 `listChildren/listDescendants` 而没看投影。

## Alternatives considered

1. 给每个面各开一个通道方法（`session.tokenUsage` / `session.turnOutline` / …）
   - 最强的理由：形状清晰，一个方法一件事，出错时定位到面。
   - 为何被否：`@Remote('projections')` **已经存在且返回全部值**。
     再开 N 个方法是把 DSH 已有的投影面翻译一遍 —— 而"翻译层就是漂移层"，
      投影一改字段，我们 N 个方法要跟着改 N 次。
     只用投影这一个口，形状变了只改一处解析。
2. 订阅投影变化（`@Remote({mode:'stream'})` 的 follow）替代一次性读
   - 最强的理由：统计条与轨迹要实时变，一次性读了就一直是旧的。
   - 为何被否：不是替代，是**分层**。首屏用一次性读（`projections`），
     实时部分复用已经接上的 `ev` 帧（会话事件流）—— 投影本来就是事件的折叠，
     事件到了本地折一遍即可。再开一条订阅流会让同一个状态有两个来源。
3. 先做写面（切模型 / 切权限 / 给子智能体发消息）
   - 最强的理由：写才是"能操作"，读只是"能看"。
   - 为何被否：**先把假数据清光是更高优先级**。现在统计条写 `302K · 缓存 0%`、
     轨迹是 `_sampleEntries`、子智能体是 `_previewSubs` —— 用户无法分辨
     哪个是真的。假数据看起来和真数据一模一样，这是最坏的一种状态。

## Consequences

- 收益：一个方法打开 A 类全部；A 类做完成功率最高，且**每一类都在消掉一处假数据**。
- 代价：
  - `projections` 的返回值是**一大包**（所有键一次给），手机要按需取。
    包大小取决于注册了多少投影 —— 已核实的键有 20+ 个，单次响应可能几十 KB。
    若实测太大，退路是"只读需要的键"（但那时就要动契约，本期不做）。
  - 投影的 `viewSchema` 是 zod strict，多字段少字段都会拒 —— 手机侧解析要
    **逐字段、认不出就不给**，不能 spread（`app_model.dart` 的
    `_parseSessionList` 已经是这个纪律）。
  - A 类每一类都要一条"没有数据时长什么样"的用例：空态与"读不到"必须分得开。

## 实施顺序（按"消掉多少假数据"排）

1. **统计条**：`tokenUsage` + `contextPressure` + `sessionStats` → 换掉写死的
   `302K · 缓存 0%` / `第 1 轮 · 5 步` / `3%`。**最小、最见效**。
2. **子智能体**：`subagentCatalog` → 换掉 `_previewSubs`；顺带接
   `@Remote('prompt')` / `interruptByParent`（手机能发消息 / 打断）。
3. **轨迹**：`turnOutline` → 换掉 `_sampleEntries`。
4. **diff / 文件**：`deliverables` + `workspace-files.read/list` → 换掉文件面板占位。
5. **模型目录**：`llm.listProviders` + 现有 `modelCatalog` → 换掉手抄四个模型名。
6. **权限读面**：`permissions` 投影 → 让权限 chip 显示电脑侧真值（写仍走
   `commands.execute('/permission …')`）。
7. 待办 / 目标 / 计划 / 设置 / 终端 / 账号 —— B 类与剩余 A 类，按需。

**每一步的验收同一条**：把真实数据接进去之后，**原来的假数据必须被删掉**，
不是留着当兜底。留着兜底就等于没接 —— 2026-10-15 的教训正是如此。
