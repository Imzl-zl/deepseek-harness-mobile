# Agent Note: 四个"看着接了其实没接"的面 —— 逐个对齐 DSH 原生能力

Status: implemented（后台任务 2026-10-15 已落地；模型选择与权限切换见下；子智能体确认做不了）

## Problem

真机跑起来后发现：App 上有四个面**显示得像真的，实际一个字节都没接 DSH**：

| 面 | App 现状 | 证据 |
|---|---|---|
| 模型选择 | 4 个写死的模型名 + 点完只弹 toast | `ui/chat_page.dart:657` 的 `const models = [...]`，`selected` 也写死 |
| 权限切换 | 只改本地 `_accessMode`，不发任何请求 | `chat_page.dart:222` 的 `_setAccessMode` 只有 `setState` |
| 后台任务 | 3 条写死示例（含假的 `flutter build apk` 输出） | `chat_page.dart:962` 的 `_previewJobs()` |
| 子智能体 | 没有 UI，也没有方法 | `METHODS` 表里没有任何 subagent 方法 |

而**这四个能力 DSH 全都有**，其中三个连接器侧甚至已经实现好了、App 一次都没调。

不写下这个设计，接下来就会各自打补丁：模型 picker 接一份真目录但切换另写一套、
权限切一个 `/permission` 但读另读一份 —— 每个面两套判据，迟早不一致。

## Decision

**一律借 DSH 原生能力，不扩展 DSH，不在通道里发明第二套语义。** 逐个面的判据：

### 一、模型选择：读已接好，写用 `session/select-model`

- **读**：`session/modelCatalog`（`@Remote('modelCatalog')`，
  `session-controller/src/index.ts:317`）+ `modelSelection` 投影 —— 连接器已实现，
  `session.list` 的行已带 `model` 字段。**这部分不用改。**
- **写**：`session/select-model` → `commands.ts:151` 的 `selectModel()`。
  已核实它做两件事：
  1. `agents.selectForNextRequest(agent, selected)` —— session 本地的选择
     （`agent.ts:333`，本质是 `append('model/selection')` + 内存缓存）；
  2. `ctx.agentDefaultModel.saveSelection(selected)` —— **顺带写回全局默认**。

  **"写回全局默认"不是产品缺陷**：手机遥控的是同一个用户自己的电脑，
  他给自己改默认模型是正常操作。`tools.md` 里"不要用 `session/select-model`"
  的理由是**测试 profile 会污染用户日常 profile**（`~/.dsh/` 全局共用），
  那是**测试关切，不是产品限制** —— 原文写在"真机联调的成本纪律"一节里。
  该注释要改，否则会把一条测试纪律误读成产品边界。

  - 插件**无法只做第 1 件**：`selectForNextRequest` 是 session-controller 的内部
    方法，`ctx.get('agents')` 拿到的注册表不暴露它；直接 `append('model/selection')`
    能更新投影（手机看得见），但更新不了驱动下一次请求的内存缓存 ——
    对活着的 agent 无效。所以第 2 件躲不掉。
  - 判据：picker 的选项来自 `modelCatalog`（**不手抄第二份**）；
    切换走 `session/select-model`；UI 上如实写"这也会改电脑上的默认模型"。

### 二、权限切换：读 `catalog()`，写走命令执行器

- **读**：`PermissionPresetService` 是 `TypertRemoteService` 且有
  `@Remote('catalog')`（`permission-presets/src/index.ts:180,292`）——
  可远程调，返回 `{options, defaultOptions, defaultPreset}`。
  另有 `permissions` 投影给 `currentValue`（同文件 `:237-244`）。
- **写**：`ctx.commands.execute('/permission <preset>', {agent, signal}, [])`
  —— "Parse and execute a known command without sending it to the model"
  （`interaction/commands/src/index.ts:333,361`）。**这是唯一写路径**
  （同文件 `:252-276` 的注释原话："the one write path a web client uses"）。
- 判据：读用 `catalog()`；写用命令执行器；`danger-full-access` 的风险确认门
  保留（§7.10 的硬规则"未授权 → 绝不生效"）。**不新增 `permission.*` 方法** ——
  那会让"权限怎么改"有两个答案。

### 三、后台任务：纯接线，零 DSH 侧改动

`job.list` / `job.follow` / `job.unfollow` / `job.kill` **连接器全部已实现**
（`handlers.ts`，按 `jobs` + `jobController` 能力位门控），`METHODS` 表里也有。
App 的 `_previewJobs()` 是唯一挡路的东西。

判据：删掉 `_previewJobs()`，改读 `job.list`；展开时 `job.follow`、收起时
`job.unfollow`（`chat_page.dart:944` 的注释已经这么写了，只是没实现）；
`job.kill` 走宿主的人类发起门面。**遵守已有的两条纪律**：`readAt` 而非 `read`
（消耗式读会吃掉模型该看的输出）、`lossy`/`gapBefore` 如实上报。

### 四、子智能体：本期做不了，DSH 侧没开口子

`ctx.subagents.listChildren` / `listDescendants`
（`subagent/src/index.ts:374,393`）存在，但**没有 `@Remote`** ——
浏览器侧调不到，手机侧也调不到。已核实在
`docs/subsystems/remote-channel.md` 的记录里。

要在通道上暴露它只有两条路，**两条都要改 DSH 参考源码**（本项目只读它）：
- 给这两个方法加 `@Remote`；
- 或改读某个投影（当前没有承载父子关系的投影）。

判据：**本期不做，UI 上不出现"子智能体"这一项**。做一个必然转圈的按钮
比没有这个按钮更糟。等 DSH 侧开口子，或接受"只在电脑上看"。

## Alternatives considered

1. 模型切换改成"只发 `model/selection` 事件，不碰全局默认"
   - 最强的理由：没有全局副作用，手机改模型完全不波及电脑。
   - 为何被否：已核实 `selectForNextRequest`（`agent.ts:333`）才是驱动下一次
     请求的那一步，而它是 session-controller 的内部方法，插件拿不到。
     只 append 事件能更新投影（手机上看得见），但 agent 下一次请求仍用旧模型 ——
     症状是"显示切了，实际没切"，比不切更糟。
2. 权限切换新增 `permission.set` 方法，直接写投影
   - 最强的理由：形状统一，和其他方法一样走封闭集。
   - 为何被否：`/permission` 是 DSH 唯一的写路径（源码注释原话），绕过它
     直接写事件会得到"两条路都能改权限"，而它们对沙箱模式与审批策略的
     生效顺序不同 —— 那正是最难查的一类不一致。
3. 后台任务先在 App 里用示例数据把界面跑起来，真数据以后再接
   - 最强的理由：界面马上能看，联调时有个样子。
   - 为何被否：已经这么做了，而后果就是现在这样 —— 真机上看到假的
     `flutter build apk` 输出和假的"等待审批"，用户无法分辨哪个是真的。
     示例数据的代价是**它看起来和真数据一模一样**。
4. 子智能体先做个空列表占位
   - 最强的理由：UI 结构先立起来。
   - 为何被否：空列表会被读成"没有子智能体"，而真因是"这条通路不存在"。
     与第 3 条同一种错误。

## Consequences

- 收益：四个面从"看起来接了"变成"真的接了"，且每个面只有一套判据；
  后台任务是纯接线（连接器侧早已就绪）；模型切换纠正了一条被误读的
  测试纪律（它会挡掉一个正当功能）。
- 代价：
  - **契约面再宽两个方法**：`session/select-model`、`settings` 之外若走
    `endpoint.describe` 已算过 —— 本次实际新增 `session/select-model` 一个
    （权限走命令执行器，不新增方法；任务用已有的 `job.*`）。
    方法数 22 → 23，`tools.md` / 契约 §5.7 / `memory.md` 的"x/22"三处要同步，
    `method-name-table.test.ts` 与 `methods.test.ts` 两道计数门禁会红着提醒。
  - **模型切换有全局副作用**：用户在手机上切模型会改电脑的默认模型。
    这是 DSH 原生行为，躲不开；UI 必须写明，不能悄悄做。
  - **子智能体本期空缺**：UI 上不出现这一项，用户要接受"手机上看不到
    子智能体树"。等 DSH 开口子。

## 落地进度（2026-10-15）

**已完成 —— 后台任务**（纯接线，连接器侧早已就绪）：

- `core/job.dart`（新）：`JobRow` / `JobChunk` / `sealed class JobFrame`
  （`JobOpened` / `JobOutput` / `JobStatus` / `JobError`）+ `parseJobFrame`。
- `SyncClient.jobUpdates`（新，广播流）**取代** `SyncClientProbe.jobFrames`
  那个列表 —— 后者是没有任何消费者的死 API，而任务面板接不上正是因为它：
  让 UI 自己解析明文 JSON 等于让"帧里是什么"有第二个答案。
- `AppModel`：`refreshJobs` / `followJob` / `unfollowJob` / `killJob` /
  `jobsOf` / `jobOutput` / `jobError` / `isJobFollowed`；
  点开会话就刷清单（**先建桶再早退** —— 桶不存在时 `job` 帧会被丢，
  而表现是"任务在跑但没有输出"）。
- `ui/chat_page.dart`：删掉 `_previewJobs()`（三条假任务，含假的
  `flutter build apk` 输出），改读 `AppModel`；`_toggleJob` / `_stopJob`
  与 `job.follow` / `job.unfollow` / `job.kill` 一对一。
- `test/job_panel_test.dart`（新，12 条）：含"电脑侧没有任务时必须是空表"
  （示例数据最大的代价是它看起来像真的）、`gapBefore` / `lossy` 显式提示、
  follow 失败撤本地标记、kill 不做乐观更新。
  做过变异校验：把"先建桶"删掉 → `opened` 帧那条恰好红。

**没做**：模型选择写路径（`session/select-model`）、权限切换
（`catalog()` + `commands.execute`）、管理页面（二维码唯一出口）。
