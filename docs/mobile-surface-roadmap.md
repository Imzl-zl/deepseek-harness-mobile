# 移动端界面接线路线图

> 本文件是"把 DSH Web 的面接到手机上"的计划与判据。现状事实以
> `docs/subsystems/remote-channel.md` 为准;因果取舍在 `.agents/notes/`。

## 0. 不变量(先读这一条)

**dsh-mobile 是 DSH 的移动端,不是另一个产品。** Web 上能看的每一个面,背后都有一个
`@Remote` 方法或一个会话投影。**接线是照形状透传,不是重新设计。**

三条推论,违反任何一条就是乱猜:

1. **Web 调哪个,手机就调哪个。** 拿不准先读 DSH 源码里 Web 那一侧的调用点
   (`packages/client/ui-*/src/client/*.ts`),不要凭方法名猜语义。
2. **没有"第二套接口"。** 若你以为某个功能要新造一个通道方法,大概率是找错了门 ——
   先搜 `@Remote` 与 `sessionProjections.register({key})`。
3. **形状逐字透传,不挑字段、不改名、不补默认值。** 挑字段的那一层就是漂移层:
   上游改一个字段,我们要跟着改 N 处。

## 1. 三扇门(已核实)

| 门 | 依据 | 覆盖 |
|---|---|---|
| **会话投影** | `packages/api/session-controller/src/index.ts:506` 的 `@Remote('projections')`,请求体只有 `{sessionId}`,返回**所有已注册投影的当前值** | 几乎全部只读面(见 §2) |
| **`@Remote` 方法** | 各控制器的 `TypertRemoteService`(48 处,`grep -rn 'extends TypertRemoteService' packages`) | 写面与独立能力 |
| **`commands.execute`** | `packages/interaction/commands/src/index.ts:360` 的 `@Remote`（无显式导出名，取方法名 `execute`；方法体在 `:361`） | 没有专用 `@Remote` 的能力(如 `/permission <档位>`) |

已核实的投影键(与"界面上看得见的东西"相关):`modelSelection` / `permissions` /
`sandboxMode` / `subagentCatalog` / `subagent` / `subagentTiming` / `deliverables` /
`tokenUsage` / `contextPressure` / `contextBreakdown` / `sessionStats` / `turnOutline` /
`todos` / `todo` / `goal` / `plan` / `inbox` / `title` / `workingDirectory` /
`agentPreset` / `agentTeam` / `userQuestions` / `sessionListMetadata` / `imageLimits` /
`llmRetry` / `tmuxContext` / `timeContext` / `subagentModelSelectionPolicy`。

## 2. 全景清单

### 2.1 已接(21/26 方法)

`repo.info` / `devices.list` / `session.list` / `session.create` / `session.subscribe` /
`session.unsubscribe` / `session.page` / `session.refetch` / `session.prompt` /
`session.modelCatalog` / `session.select-model` / `session.projections` /
`permission.catalog` / `permission.switch` / `interaction.respond` / `job.list` /
`job.kill` / `job.follow` / `job.unfollow` / `endpoint.describe` / `sync.hello`
(共 21 个方法名;26 是契约封闭集的规模,差额是契约列了但没实现的 5 个:
`session.cancel` / `settings.describe` / `settings.update` / `credentials.set` /
`credentials.unset`,依据见契约 §5.8)。

已接的**面**:会话流/历史/发送/取消、新建会话、审批/提问/计划审查、后台任务全四条、
统计条(`tokenUsage`/`sessionStats`)、模型名与切换、**权限档(读目录 + 切档)**、
端点切换、配对扫码。

### 2.2 一个方法就能读(A 类,按"消掉多少假数据"排)

| 面 | 投影键 | 手机上的位置 |
|---|---|---|
| 子智能体 | `subagentCatalog` | 侧抽屉第三个面板 |
| 轨迹 | `turnOutline` | 轨迹页 |
| diff / 交付物 | `deliverables` | 侧抽屉文件面板 |
| 待办 | `todos` / `todo` | 新面板或并入轨迹 |
| 目标 / 计划 | `goal` / `plan` | 只读横幅 |
| 上下文明细 | `contextBreakdown` | `sheet-context` |

(权限档的读面已接:当前值走 `permissions` 投影,可切清单走 `permission.catalog`
—— 它不是"一个方法就能读"那一类,因为**名单在电脑侧的部署配置里**。)

### 2.3 有独立 `@Remote`,要各自接(B 类)

| 组 | 方法 | DSH 依据 |
|---|---|---|
| 文件 | `read` / `readBytes` / `stat` / `list` / `changes` | `packages/api/workspace-files/src/index.ts:232,256,289,302,339` |
| 模型目录补充 | `listProviders` / `listConfigurableProviders` / `discoverModels` | `packages/llm/llm/src/index.ts:470,542,630` |
| 工作区 | `pick` / `list` / `createDirectory` / `create` / `initializeDefault` / `rename` / `delete` / `insertBefore` / `insertSessionBefore` | `packages/api/workspace-controller/src/index.ts` |
| 会话管理 | `archiveSession` / `unarchiveSession` / `pinSession` / `unpinSession` / `rename` / `fork` / `search` | 同上(`workspace-controller`) |
| 会话附件与队列 | `attachment` / `updateQueue` / `openWorkspacePath` / `workspacePathApplications` | `packages/api/session-controller/src/index.ts` |
| 设置 | `describe` / `update` / `replace` / `mutate` / `openSettingsDocument` | `packages/api/settings-controller/src/index.ts:97,115,132,151,166` |
| 终端 | `environment` / `shells` / `list` / `create` / `retain` / `follow` / `write` / `resize` / `rename` / `close` | `packages/api/terminal-controller/src/index.ts` |
| 账号 | `getState` / `getProfile` / `getBalance` / `getUnnotifiedBonuses` / `ackBonusNotified` / `startSignIn` / `cancelSignIn` / `hasRunningAccountTasks` / `signOut` / `watch` | `packages/api/account-controller/src/index.ts` |
| 技能 | (skill-catalog) | `packages/api/session-controller/src/skill-catalog.ts:20` |
| 子智能体(写) | `prompt` / `interruptByParent` | `packages/subagent/subagent/src/index.ts:445,512` |
| ~~命令~~ | ~~`execute`~~ | `packages/interaction/commands/src/index.ts:360`。**已接**(2026-10-15):`permission.switch` 经它跑 `/permission <档位>` |

### 2.4 手机上不做(C 类)

桌面聊天/会话完整形态、目录选择器、唤起电脑应用、插件逐页管理、内嵌浏览器/Office 预览、
快捷键/窗口管理、workflow/schedule/skill 的完整运行态、实验性功能。
理由逐条见 `.agents/notes/proposed/2026-10-15-phone-surface-inventory.md`。

## 3. 接线顺序

| # | 目标 | 为什么是这个顺序 |
|---|---|---|
| ~~1~~ | ~~**权限切换**:读 `permissions` 投影 + 写 `commands.execute('/permission <档位>')`~~ | **已接**(2026-10-15):读 `permissionPresets.catalog()` + 写 `commands.execute('/permission …')`,手机侧三档手抄已删 |
| 2 | **文件**:`workspace-files.read` / `list` / `changes` | 文件面板现在是删掉假数据后的空态;一通就能显真文件 |
| 3 | **设置**:`settings.describe` / `update` | 42 项搬运清单(`docs/settings-porting-notes.md`)的入口 |
| 4 | **会话管理**:`workspace-controller` 的 `rename` / `fork` / `archiveSession` / `pinSession` | 会话管理齐活;顺带解决"建错了删不掉" |
| 5 | **子智能体写面**:`subagent.prompt` / `interruptByParent` | 从"能看"到"能操作" |
| 6 | **待办 / 目标 / 计划**:纯投影读 | 零新方法,只加解析 |
| 7 | **终端 / 账号**:形态未定,放最后 | 手机上长什么样还没设计,先接会做出一个缩小版桌面 |

## 4. 单个方法的接线清单(照这个走,别跳步)

1. **读 DSH**:找 Web 的调用点(`packages/client/ui-*/src/client/*.ts`)确认方法名与
   请求/响应形状;确认它是 `@Remote` 还是有投影。**引用时给 `packages/...:行号`。**
2. **适配层**:`connector/src/dsh/<组>.ts` 的 Port 接口 + `create<X>Port(controller)`。
   类型收窄(branded id)**只在这一处**;本层对外只说 `string`。
3. **handler**:`connector/src/handlers.ts` 里加 `'面.方法': async (params, ctx) => …`。
   参数**逐个校验**,坏的抛 `protocol/bad-frame`(别让它变成 DSH 侧的 500)。
4. **能力位**:若依赖可选服务,加进 `connector/src/dsh/caps.ts` 的 `OPTIONAL_SERVICES`,
   并在 `index.ts` 的注入点**按能力位挂** —— 缺服务时方法不出现,而不是挂上去回
   `connector/unsupported`。
5. **封闭集**:`connector/src/protocol/methods.ts` 的 `METHODS` 与(若是写操作)
   `IDEMPOTENT_METHODS`。
6. **契约**:`docs/subsystems/remote-channel.md` §5.7 方法表加一行 + §5.8 的 DSH 依据表
   + §5.8 的"未实现"清单(若原来列了它)。**方法数变了两道计数门禁会红着提醒。**
7. **App 数据层**:`app/lib/data/app_model.dart` 加方法;失败**兜住所有异常**
   (`refreshSessions` 的纪律),别只接 `ProtocolException`。
8. **App UI**:接真数据;**同时删掉对应的假数据**,不留兜底。
9. **测试**:`connector/tests/<名>.test.ts`(形状/校验/失败)+ `app/test/<名>_test.dart`
   (解析/空态/失败留声)。**期望值从生产代码路径取,不要在手测里重打一遍常量。**
10. **计数与文档**:`memory.md` 的"方法面 x/24"、`tools.md` 的方法数、cookbook 的
    "x/24"三处同步。
11. **门禁**:`cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test`;
    `cd app; flutter test && dart analyze --fatal-infos lib test integration_test`;
    `node protocol/verify-{fixtures,loopback,vectors}.mjs`;
    `node app/tools/verify-platform-boundary.mjs`。

## 5. 已知陷阱(都踩过,别再踩)

| 坑 | 症状 | 处置 |
|---|---|---|
| **方法名带连字符** | `session.select-model` 被 `[\w.]*` 截成 `session.select`,新方法**静默漏检**而门禁看起来通过 | `method-name-table.test.ts` 的字符类写 `[\w-]` |
| **Dart null-aware element** | `?x: x` 的 key 取**值的字符串形式**,展开成 `high: high`;而 `dart analyze` 反过来建议你改过去 | 可选字段用显式 `if (x != null) 'k': x`,加 `// ignore: use_null_aware_elements` 并写理由 |
| **注释里写 `ctx.<键>`** | `tests/layering.test.ts` 的 `service-key-registered` 按文本扫,把注释里的键当成未登记服务键 | 注释里别出现 `ctx.<服务键>` 字样 |
| **测试替身漏新成员** | `Pick<SessionsPort, …>` 加一个方法,一批测试的假实现同时红 | 一个文件里可能有**多处** `sessions:` 替身,逐处补 |
| **断言完整调用序列** | 加一个"顺带拉的方法"就红一次 | 只比被测方法:`calls.where((m) => m == 'x').toList()` |
| **`putIfAbsent` 早退** | `job` 帧不带 sid,桶不存在就被丢,症状是"任务在跑但没有输出" | **先建桶再早退** |
| **`integration_test/` 不在 `flutter test` 里** | 改了统计条,`ui_flow_test.dart` 断言旧写死值,而默认门禁看不见 | 动 `app/lib/ui` 后单独跑 `flutter test integration_test/<文件>` |
| **假数据不留兜底** | 留着当 fallback 等于没接 | 真数据接上的同一批里删掉假数据 |
| **替身绕开了真值的信封** | DSH 的 `@Remote('projections')` 回的是 `{kind, asOfSeq, values}`,而测试替身直接回 `values` 映射 —— 于是连接器把整个信封透传给手机,`tokenUsage` / `permissions` / `subagentCatalog` **一个都取不到**,统计条与权限档在生产里全是空态,而单测全绿 | **替身必须复现真值的形状**;判据是"把 DSH 的返回类型读一遍",不是"照手机要的形状写"。2026-10-15 修在 `connector/src/dsh/projections.ts` 的 `valuesOf` |

## 6. 完成判据

一个面算"接上了",要同时满足:

- 手机显示的值与 Web 同一份真值(不是手抄的第二份);
- 没有数据时显示空态 + 一句"数据来自哪",**不塞假的**;
- 失败留声(`AppModel.lastError`),不静默;
- 有专属测试覆盖解析/空态/失败三条;
- 契约 §5.7、`memory.md`、`tools.md`、cookbook 四处计数与描述一致。
