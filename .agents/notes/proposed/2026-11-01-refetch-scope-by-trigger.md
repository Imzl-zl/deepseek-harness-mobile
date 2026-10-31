# Agent Note: 一次重取该拉多少 —— 按触发源拆快照，而不是按函数捆

Status: proposed

## Problem

`host` 帧落地后（`implemented/2026-10-31-host-state-sync.md`），**一条通知 = 一次
`session.list` 重取**，而 `AppModel.refreshSessions()` 是个**捆**：它先拉行，然后
顺带拉六个与会话无关的东西（`app_model.dart:2844-2887`）：

| 序 | 线上方法 | 与本条通知的关系 |
|---|---|---|
| 1 | `session.list` | 真正要的 |
| 2 | `session.modelCatalog` | 无关（模型**目录**没变，变的是某会话的选择） |
| 3 | `permission.catalog` | 无关（部署配置） |
| 4 | `workspace.list` | 无关（分组 / 归档 / 置顶） |
| 5 | `agentPresets.list` | 无关（部署配置） |
| 6 | `settings.describe` | 无关（除非这条通知本来就是设置） |
| 7 | `repo.info` | 无关（版本 / 能力位，进程级） |

于是 **1 通知 → 7 个往返**。四条触发点各自都是这样：

- `model/selection`（切模型）→ `session.list` + `session.projections` → **8 请求**（两个 key 各 7）；
- `session/title`（生成标题）→ 同上 8；
- `permission/preset` → 只有 projections 那一路 → 7；
- jobs 增删 → 1（`job.list` 是窄的，没进这个捆）。

**同一笔浪费在"自己发起的写"上也在**：切模型 / 分支 / 会话页的"重试"都直接调
`refreshSessions()`（`app_model.dart:1232,3369`；`ui/chat_page.dart:577-583`），
一次点击 7 个往返。

弱点不是"请求多"，而是**判据错位**：这条通道回答的是"哪一份快照可能过期"，
而重取动作按"函数"而不是按"那一份"来做。捆在的时候，触发点说得再准，
落到线上也是"顺手把六个别的东西也问一遍"。

## DSH 怎么做的（判据出处）

1. **模型目录是懒加载 + 按 Host 代次缓存 + 一次性共享**,**不跟会话清单一起刷新**:
   `ModelCatalogDirectory.load()` 在 `status === 'ready'` 时直接返回缓存、在飞时复用同一个
   promise(`packages/client/ui-model-selection/src/client/catalog.ts:44-82`);
   只有显式 `refresh()` / `resetGeneration()` 才失效重拉(`:95-106`)。
2. **失效点是五条宿主事件**,不是"任意变化":
   `llm/adapters-updated`、`llm/models-updated`、`settings/document-updated`、
   `credentials/record-updated`、`credentials/reference-updated`
   (`ui-model-selection/src/client/service.ts:54-58`;事件声明在
   `packages/llm/llm/src/types.ts:24,30` 与 `packages/credentials/.../types.ts:87,99`)。
3. **会话清单是"行级事件 + 脏缓存重建",不是整表重取**:浏览器侧 `manager` 收
   `api-session/added`(整行,含 list 投影)/ `removed` / `status` / `activity` 后只
   `recordMutation` + `markDirty()`,读的时候 `ensureFresh()` 重建快照
   (`api/session-controller/src/client/sessions/manager.ts:629-631,671-676,706-748`;
   `sessions/notifier.ts:33-66`)。**没有一条"发个事件然后重拉全表"**。
4. **清单行带 list 投影提示**(`types.ts:157-163` 的 `projections?: SessionProjectionHints`),
   而连接器本来就原样透传(`connector/src/dsh/sessions.ts:354`);手机侧行解析
   还优先用 `values.modelSelection`(`app/lib/wire/rpc/session.dart:294`)。
5. **另外四个面没有"它变了"的宿主事件**(逐条查过):
   - `workspace` 包只 emit `workspace/session-activity` / `workspace/session-stop`
     (`packages/workspace/workspace/src/index.ts:129,147`)——那是"会话活动/停止",**不是**
     "工作区表变了";`api/workspace-controller` 一个 `emit(` 都没有;
   - `agent-preset-registry` 只 emit `agent-preset/selected`(`preset/agent-preset-registry/src/index.ts:77`);
   - `permission.catalog` 读的是部署配置(`cordis.patch.yml` 的预设表);
   - `repo.info` 是进程级事实(版本 / 能力位)。
   ⇒ 它们**只该在连上时拉一次**(以及手机自己发起、回执里带回全集的那几笔写)。

## Decision

**按"谁让它过期"把快照拆开登记,让 bootstrap 就是登记表的 `connectLanding` 一列。**

两批落地,各自独立可验:

### 第 1 批(app 侧,不动协议)

1. `refreshSessions()` **拆成两半**:
   - `refreshSessionRows()` —— 只做 `session.list` + `_applySessionList` + prune + 报错;
   - `refreshHostCatalogs()` —— 现在的 2/3/5/7 四件(模型目录、权限目录、预设目录、`repo.info`);
   - 4(`workspace.list`)与 6(`settings.describe`)已经是独立方法,只是被捆在里面。
2. **登记表成为"拉什么"的唯一清单**(`app/lib/data/host_state.dart`):把上面每一项
   各登记成一个 key,`triggers` 写清它该在哪个时机重取:

   | key | 触发点 |
   |---|---|
   | `session.list` | notification / connectLanding / appResume |
   | `session.projections` | notification / openSession / connectLanding / appResume |
   | `settings.describe` | notification |
   | `job.list` | notification / openSession |
   | `session.modelCatalog` | notification(仅 `llm/*`、`credentials/*`、`settings/document-updated`) / connectLanding |
   | `permission.catalog` | connectLanding |
   | `agentPresets.list` | connectLanding |
   | `workspace.list` | connectLanding |
   | `repo.info` | connectLanding |

3. **bootstrap 变成"跑登记表的 `connectLanding` 一列"**(`landAfterConnect()` 今天就是
   调 registry):`refreshSessions()` 这个名字**从产品路径消失**,只留
   `refreshSessionRows()` 给"自己发起的写"与界面上的重试用。于是
   - 通知路径:**rows 只拉行**(有 `session.list` 的那条通知 = 1 请求,不再是 7);
   - 自己的写(切模型 / 分支 / 重试):同样 1 请求;
   - 连上 / 回前台:整份 bootstrap(9 项)照旧 —— 那是**一次**的事,不是高频路径。

### 第 2 批(连接器侧,加一条触发源)

4. 给 `session/modelCatalog` 补通知:听那五条宿主事件
   (`llm/adapters-updated` / `llm/models-updated` / `settings/document-updated` /
   `credentials/record-updated` / `credentials/reference-updated`)→ 发
   `{keys:['session.modelCatalog']}`。
   这**不只是省请求,是补一个今天没有的能力**:在电脑上加/换模型或改密钥后,
   手机的模型选择器**不重连就永远看不到**(现在只有连上时才拉目录)。

### 不做

- 不给 `permission.catalog` / `agentPresets.list` / `workspace.list` / `repo.info` 编触发源:
  它们没有宿主事件(见判据 5),编一个"每 N 秒"或"每次通知都拉"就是替宿主做决定。
- 不把 `session.list` 的整行改成推送(见被否方案 2)。

## Alternatives considered

1. **在合并器里表达"拉 session.list 蕴含 settings"**(implied keys:重取 A 时顺带重取 B)
   - 最强理由:改动最小(只在 `HostStateRefresher` 加一张覆盖表),不动调用点、不动协议。
   - 为何被否:它只治**重复**(settings 被拉两次),不治**浪费**(仍然 7 个请求);
     而且"谁蕴含谁"是一份隐式依赖表,`refreshSessions` 里再加一项就得同步改它 ——
     等于把捆的耦合从代码搬到数据里,没有变简单。
2. **清单行改成推送**(连接器在 `api-session/added` 时推"一行",手机按 `sid` upsert)
   - 最强理由:**DSH 自己就这么做**(判据 3),而且行级精确、天然幂等、省掉整表重取;
     切模型/标题/活动时间的推送体积是一行 JSON,比 7 个请求小得多。
   - 为何被否:与上一条笔记的核心决定冲突 —— 那条定的是"**提示重取,不推数据**"
     (推数据 = 第二份真值)。真要走这条,得先推翻"快照方法是宿主权威唯一来源",
     并给清单行引入一套与 `seq`/`itemId` 无关的合并语义(哪一行新?没有序号可比 ——
     DSH 有 `mergeOrderedBaseline` 与 `asOfSeq`,我们一条都没有)。代价远大于收益,
     且它解决的是"省一次往返",而本轮的问题是"一次拉太多"。
3. **保持现状**:把 7 个请求当成"一次完整快照刷新"。
   - 最强理由:零改动、行为最稳、没有 bootstrap/通知两条路径要防漂移。
   - 为何被否:它把"通知越准越好"这条投资浪费掉 —— 触发点精确到 `model/selection`,
     落地却是整表刷新;而且"自己的写 7 个往返"与用户点一下要等一次完整快照是同一笔账。
     逐条测试也不需要它:`host_state_test` 已经能断言"这条通知只发出哪些方法"。
4. **把 `repo.info` / 目录们缓存到本地、只在连上时校准**
   - 最强理由:理论上目录变化极慢,缓存过夜也能用。
   - 为何被否:`docs/subsystems/ui-state.md` §1 已经裁定 `host` 类状态"手机不缓存过夜",
     而目录是 host 权威;缓存日期就会重演"手机显示一个电脑上已经没有的模型"。
     要省的是**请求数**,不是**新鲜度**。

## Consequences

- 收益:
  - 一条通知的往返从 **7~8 → 1~2**(切模型 = rows + projections;标题 = 同;权限 = projections);
    自己发起的写从 **7 → 1**。
  - **补上一个缺口**:凭据 / 模型提供方在电脑上变化后,手机的选择器能自己跟上(今天不能)。
  - 登记表成为"拉什么、何时拉"的唯一清单;`refreshSessions()` 这个名字消失,捆也就没了
    —— 以后想加"某个新快照",只能登记,不能偷偷塞进一个函数。
- 代价 1:**协议封闭集 +1 个 key**(`session.modelCatalog`)⇒ 要同步契约 §5.9 的 key 表、
  连接器的 `HOST_STATE_KEYS`、app 的 `HostStateKey`(有跨端门禁 `host_state_test`),
  并补一条"事件 → 通知"的连接器用例。
- 代价 2:**两条路径要防漂移**:bootstrap 是"registry 的 connectLanding 一列",
  所以"连上时该拉什么"不再由函数体决定 —— 好处是不会漂,坏处是**改 `connectLanding` 一列
  就等于改首屏行为**,得靠 `landAfterConnect` 的既有落点测试兜(落点依赖行里的
  `updatedAt`/`running`,所以 rows 必须在落点之前完成)。
- 代价 3:重新验证面变大 —— 首屏落点、回前台、自己的写、断连重连都要各看一遍
  (它们今天都在"7 请求"的同一条路上,拆开后各自独立)。
- 代价 4:`session.modelCatalog` 的触发源有 5 条宿主事件要接,其中 `credentials/*` 两条
  在连接器里**没有现成用法**(首次出现),要在 `index.ts` 新加两个 `ctx.effect`。

## Testing

- `app/test/host_state_test.dart` 扩:
  - 每个新 key 至少一个触发点(已有机械判据);
  - **一条通知只发出该 key 的方法**:`{keys:['session.list']}` ⇒ 恰好 1 次 `client.call`,
    且方法名就是 `session.list`(现在是 7 次,这条会红);
  - `connectLanding` ⇒ 9 个方法各一次;
  - `repo.info` / `permission.catalog` / `workspace.list` / `agentPresets.list`
    **不接受 notification**(把这三个写进一条通知 ⇒ 零请求)。
- `app/test/connect_landing_test.dart` / `connect_landing` 相关:落点仍要等 rows
  (行里的 `updatedAt`/`running`),所以断言"落点前 rows 已到位"。
- `connector/tests/host-state-notice.test.ts` 扩:五条目录事件的映射
  (`llm/adapters-updated` 等 ⇒ `{keys:['session.modelCatalog']}`),以及
  "`settings/document-updated` 同时命中 `settings.describe` 与 `session.modelCatalog`"。
- 真机:在电脑上换一个模型的凭据 / 改 `agent-default-model`,手机**不重连**打开模型选择器
  应能看到新模型(这是今天做不到的,所以有一条"改前必红"的对照)。

## Open questions（实施前要定）

1. `session.modelCatalog` 的 5 条事件里,`settings/document-updated` 会让**任何**命名空间的
   设置写触发一次目录重取(手机可读的那几个之外没有过滤)。要不要只对
   `llm-*` / `permission` / `agent-preset-registry` 这几个命名空间发?
   (倾向:不过滤 —— 目录取回的是一整包,过滤表是第二份"哪些设置影响模型"的知识,
   而 DSH 浏览器侧同样不过滤:`service.ts:56`)
2. `permission.catalog` 真的没有宿主事件吗?部署配置变化走的是 `configEditor`(插件面板),
   那条路会不会 emit 什么?**实施前要再核实一次**(查不到就维持 connectLanding-only)。
3. 首屏是否可以"行到位就落点,目录并行"?今天 `landAfterConnect` 等全部 9 项才落点,
   拆开后要不要把"等"收窄成"只等 rows"?收益是首屏更快,代价是落点后目录还会再刷一次
   (界面会闪一下"拿不到目录"→有)。**倾向不动**(首屏是低频路径,不动时序最稳),
   但要把它写成明确的不做,而不是忘了。
4. 自己的写要不要也走 registry(立即触发、不压 150ms 窗口)?
   **倾向要** —— 那样"切模型之后 chip 什么时候变"只有一处实现;代价是 `selectModel`
   不再直接 `await refreshSessions()`,要改成 `await triggered(ownWrite, sid:)` 并
   在测试里断言方法名。
