# Agent Note: `caps` 收口 —— 判据是"会不会引发注定失败的调用"

Status: implemented

## Problem

`caps` 里还剩三个键没解析：`subagents` / `approval` / `questions`
（上一批补了 `jobs`，见 `implemented/2026-11-11-jobs-capability-gate.md` 的遗留段）。

**"还有几个键没读"不是判据**：五个键里决定"画不画那一屏"的四个（`references` /
`files` / `changes` / `plugins`）与决定"发不发一次调用"的 `jobs` 是两类东西。
所以这一批先逐条对照三件事，再决定动不动代码：

1. 连接器缺该服务时**挂不挂对应方法**；
2. 手机有没有**无条件**调它；
3. 缺了时**界面说什么**。

| 能力位 | ① 连接器挂不挂方法 | ② 手机有没有无条件调 | ③ 缺了时界面 |
|---|---|---|---|
| `subagents` | `subagent.prompt` 只在 `deps.subagents` 在时挂（`connector/src/handlers.ts:931`） | **没有**。它是"在子会话里发一句话"的写入口（`app/lib/model/command.dart:38`、`app/lib/ui/chat_page.dart:689`），而一次性 / 未知档的子会话输入栏本来就置灰（`app/lib/data/composer_gate.dart:183` 的 `subagentReadOnly`）—— 入口本身来自子智能体目录 | 目录来自 `session.projections` 的 `subagentCatalog`，缺服务 ⇒ 空目录 ⇒ 面板说「没有子智能体。」（`app/lib/ui/subagent_tree.dart:58`） |
| `approval` | **不决定任何方法**：`caps.approval` 只出现在 `caps.ts:225`，全仓没有任何挂载判据读它 | 没有（审批是**事件**，走 gateway 的 waterfall） | 审批卡不会产生（缺服务 ⇒ 宿主不问），所以没有"缺能力"的表现 |
| `questions` | `interaction.respond` 挂在 `userQuestions` 上（`connector/src/index.ts:1047`） | 没有无条件调用；但**答审批卡也走这个方法**（见下） | 手机上每张审批卡都弹「没发出去，再试一次」（`app/lib/ui/chat_page.dart:502`），卡片留着、永远答不掉 |

结论：**②一条都不成立** ⇒ 手机侧**不加任何能力位**。这也解释了为什么加它没用：
`subagents` 的"缺服务"已经如实降级成空目录（与任务面板同一形状），`approval` 根本没有方法面。

但对照表第三行翻出一个**真正的缺陷**，它不是"少一个能力位"，而是挂载判据错了：

> `interaction.respond` **服务两类**：审批的在途 claim（`interaction-claims.ts:203-212`
> 把答案映射成 `allowed-once` / `rejected`）与提问的答案批次。而它按 `userQuestions`
> 单独挂。缺 `userQuestions` 时提问事件确实不会产生，但**审批照旧会有** ——
> 审批事件来自 gateway 的 waterfall（`mount-interactions` 那一步），与提问服务无关。
> 于是那种部署上，手机上每张审批卡都注定答不掉，而**方法面里其实什么都不缺**
> （`settleClaim` 与 `ask()` 都在，`createQuestionFaceDeps` 也只在 `answer` 那条路上
> 才读 `userQuestions`，见 `connector/src/dsh/questions.ts:96-100`）。

第二条缺陷是上一轮留下的：`_jobsAvailable` 默认 `true`（老连接器照样能拉），
所以**首屏还没有读到 `repo.info` 时**开一个会话仍会发一次 `job.list`。
首屏那条路的时序是「九项并行发起 → **只等行** → 落点」（`app/lib/data/app_model.dart:3360`
的 `landAfterConnect`），落点开会话时 `repo.info` 往往还在飞 —— 缺 jobs 的部署上
**每进程第一次**仍会假失败一次。

## Decision

### 1. `interaction.respond` 按"两个来源至少有一个在"挂（连接器）

`connector/src/index.ts:1047` 的判据从 `userQuestions` 单独改成一个与条件：

```ts
ctx.get('userQuestions') === undefined && ctx.get('approval') === undefined
  ? null
  : createInteractionFace({ … settleClaim … })
```

提问那半边的缺服务仍由 `createQuestionFaceDeps` 自己判（它只在 `answer` 里读键），
所以这里不必再挡一次 —— 一条判据只有一个家。

### 2. `refreshJobs` 等那一次已经在飞的 `repo.info`（手机）

"正在飞的那一次重取"这个事实**已经有主了**：`HostStateRefresher._inFlight[key]`
（重取器本来就要等它，见 `app/lib/data/host_state.dart` 的 `_run`）。所以只给它加一个
只读 getter `inFlightOf(key)`，让 `refreshJobs` 在 `_repoInfoKnown == false` 时先
`await` `inFlightOf(HostStateKey.repoInfo)`，再按 `_jobsAvailable` 决定发不发。

没有在 `AppModel` 里另存一份 `_repoInfoInFlight`：那会是同一个事实的第二个家，
而两份的清除时机必然漂。也没有把它做成 `HostStateFetch` 的 `dependsOn` 字段 ——
那条依赖今天只有一个用户，多一个登记表概念换不到任何东西。

为什么**不是**"未知一律不发"：那条路有两个比原缺陷更贵的后果 ——
① `repo.info` 读不到（应答读不出来 / 连接抖动）时任务面会**永远黑着**，
而那时 `job.list` 很可能照样能用；② 每一个 `job.list` 的既有用例都得先造一份
`repo.info` 应答（`job_panel_test` / `notice_test` / `snapshot_digest_test` …），
而它们测的不是能力位。等"在飞的那一次"把两件事都避开了：这条判据不新增触发点
（首屏批次本来就在读），也不改"从未读过 `repo.info`"的路径行为。

## 准入判据

| 用例 | 钉什么 |
|---|---|
| `app/test/jobs_capability_timing_test.dart` 第 1 条 | 首屏：`repo.info` 还没回来时开会话 ⇒ **不发** `job.list`；回来是 `false` ⇒ 一直不发 |
| 同文件第 2 条 | 回来是 `true` ⇒ **等它**再发一次（顺序断言：`repo.info` 在 `job.list` 之前） |
| 同文件第 3 条 | 从没读过 `repo.info`（单测 / 老流程）⇒ 照旧发，且 `refreshJobs` **不自己**去读能力位 |
| `connector/tests/interaction-availability.test.ts` 第 1 条 | 挂载判据的源码形状含 `approval`（装配面没有"起真 ctx"的用例，沿用 `assembly-wiring.test.ts` 的读源码口径） |
| 同文件第 2 条 | `handlerDeps.interaction` 只有一处赋值（两处就是两条真值） |
| `app/test/jobs_capability_test.dart` 3 条 | 上一批的三条仍绿（`caps.jobs` 的解析与"缺就不发"） |

变异校验（先 `grep` 确认变异落地，再看红）：

| 变异 | 结果 |
|---|---|
| `refreshJobs` 的等待条件短路成 `if (!_repoInfoKnown && false)` | 第 1、2 条红（`Expected: not contains 'job.list'`），第 3 条绿 —— 恰好是"等待那条机制" |
| 连接器判据退回 `ctx.get('userQuestions') === undefined` | 正好 1 条红（`interaction-availability` 第 1 条），另一条仍绿 |

门禁：`dart analyze --fatal-infos` 0、`flutter test` 1859 项全绿、`verify-size` 19 条自检、
`verify-platform-boundary` 873 项；connector `tsc --noEmit` / `pnpm build` / `pnpm test`
**854 项**全绿（fixtures 仍 454、向量仍 49）。

## Alternatives considered

1. **手机侧加 `caps.questions`，缺了就把答复按钮置灰**
   - 最强的理由：一个开关就把"注定失败"变成"点了没反应"。
   - 为何被否：它会把**本来能修好的事藏起来**。审批应答不依赖 `userQuestions`，
     置灰等于承认"这个部署上审批答不了"，而根因只是连接器少写了一个 `||`。
     同时它会引入一个"能力位只看一半"的先例（`caps.questions == false` 而审批在）。
2. **把 `openSession` 的 `job.list` 触发整体后移到 `repo.info` 到达之后**（上一轮列的 (a)）
   - 最强的理由：触发顺序在登记表里一次表达，读起来最直。
   - 为何被否：那会改**所有 key** 的触发时机（`host_state.dart` 的语义从"每个 key 各管
     各的触发点"变成"整批按顺序"），而首屏九项并行正是 `connect-landing.md` §2 的判据。
     为一个 key 的时机把整张表的语义换掉，代价与收益不成比例。
3. **未知一律不发**（上一轮列的 (b)）
   - 理由与被否见上（`repo.info` 读不到 ⇒ 任务面永远黑；既有用例全要补一份应答）。
4. **用错误码试探**（`job.list` 回 `connector/unsupported` 就当"没有这个面"）
   - 最强的理由：零时机问题，自愈。
   - 为何被否：能力位模型存在的理由就是"**不靠错误码试探**"（契约 §7）。
     把 `unsupported` 当能力位，等于让"方法真的写错了"也静默降级。
5. **把审批的应答拆成第二个方法**（`approval.respond`）
   - 最强的理由：两类的挂载判据就能各自成立，不必用 `||`。
   - 为何被否：契约 §5.7 只定义了一个应答入口，而两类的载荷形状本来就是同一个批次
     （`interaction-face.ts` 的 `respond` 第一段校验之后就分叉）。加一个方法等于让
     "答一次"有两处入口，而手机那条路会在两个错误码集合之间漂。

## Consequences

- 收益：缺 `userQuestions` 的部署上审批第一次变得可答；缺 jobs 的部署上"每进程一次假失败"
  没了。两条都不新增能力位、不新增触发点。
- 代价：`AppModel.refreshJobs` 多了四条（一次等待 + 一段理由）⇒ `app_model.dart`
  5200 → 5215 行，棘轮表因此提到 **5250**（`ceil(实测, 50)`）。这是**有意的提账**，
  在 diff 里是一行可见的数字；**方法数不变**（177）—— 等待逻辑借了
  `HostStateRefresher.inFlightOf`，没有在 `AppModel` 里新增成员。另一条更便宜的路是
  把这个等待写进 `host_state.dart` 的 `_refetchJobs`，但它拿不到重取器的在飞表
  （那个函数的入参只有 `HostStateTarget`），为它改登记表签名是更大的动作。
- 代价：`refreshJobs` 多了一条"等"的语义 —— 它依赖"首屏批次会发起 `repo.info`"这条既有
  事实。写进用例的第 3 条当反面钉子（没有在飞就不等）。
- **不做**（用户 2026-11-12 判定）：任务 / 子智能体面板在缺服务时显示「没有后台任务。」/
  「没有子智能体。」——**"没有就是没有"**，不必再区分"这台电脑没这个面"。它与上一批否掉
  "藏 tab"的理由同源（tab 结构不该是能力位的函数），这条从遗留表里划掉，不再重开。
- 遗留（**未证**）：`approval` 服务缺、`userQuestions` 在的部署里，`interaction.respond`
  照旧挂着（与改动前一致）；那种组合下审批事件不会产生，所以没有可失败的调用。
  没有为它加第二条判据 —— 加了就是替宿主决定"没有 approval 时不准答提问"。
- 顺带校准：`tools.md` 的两处项数此前已漂移（app 写 1805 实测 1838，connector 写 851
  实测 852），本批分别改成 **1859** / **854**。
