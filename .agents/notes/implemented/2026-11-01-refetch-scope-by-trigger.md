# Agent Note: 一次重取该拉多少 —— 按触发源拆快照，而不是按函数捆

Status: implemented（2026-11-01，两批都已落地；第 2 批的事实与新增代价见文末「第 2 批已落地」）

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
5. **权限预设目录有它自己的事件**:`permission-presets/catalog-changed`,浏览器侧收到就
   `invalidate()` + `refresh()`(`ui-permission-presets/src/client/catalog.ts:46-49`)。
   ⇒ 它**不是**"只连上拉一次"的那种目录(与上一版方案里的判断相反,已改)。
6. **目录在"连接代次变化"时重拉,而不是跨重连保留**:模型目录的 `resetGeneration()` 挂在
   `connection/reset` 上(`ui-model-selection/src/client/service.ts:48-51`),权限目录同一条纪律
   (`:50-56` 的 generation 订阅)。
7. **仍然没有"它变了"事件的四个面**(逐条查过):
   - `workspace` 包只 emit `workspace/session-activity` / `workspace/session-stop`
     (`packages/workspace/workspace/src/index.ts:129,147`)——那是"会话活动/停止",**不是**
     "工作区表变了";`api/workspace-controller` 一个 `emit(` 都没有;
   - `agent-preset-registry` 只 emit `agent-preset/selected`(`preset/agent-preset-registry/src/index.ts:77`);
   - `repo.info` 是进程级事实(版本 / 能力位);
   - `session.list` 那一行的**内容**变化在宿主侧是有事件的(`api-session/activity` 等),
     但我们**不推数据**(`implemented/2026-10-31-host-state-sync.md` 的「代价 3」那条),
     所以手机侧只能重取快照 —— 见下方「不做」的第二条。

## Decision

**总纲:快照按"谁让它过期"拆开登记,`connectLanding` 一列就是首屏。**

但**不是照抄 DSH 就够了** —— 它的前提是"桌面浏览器 + 常连 + 同一进程",手机上是
"单 socket 多路复用 + 可能经计费中转 + 会闪断 + Flutter 整树重建"。所以有三处
**刻意不照抄**(下面 3/4/5 三条),另有一处**照抄**(第 5 条:重连重拉目录)。
两批落地,各自独立可验。

### 第 1 批(app 侧,不动协议)

1. `refreshSessions()` **拆成两半**:
   - `refreshSessionRows()` —— 只做 `session.list` + `_applySessionList` + prune + 报错;
   - `refreshHostCatalogs()` —— 模型目录、权限目录、预设目录、`repo.info` 四件。
   - `workspace.list` 与 `settings.describe` 本来就是独立方法,只是被捆在里面。
2. **登记表成为"拉什么、何时拉"的唯一清单**(`app/lib/data/host_state.dart`):

   | key | 触发点 | 依据 |
   |---|---|---|
   | `session.list` | notification / connectLanding / appResume | 行是落点与 chip 的来源 |
   | `session.projections` | notification / openSession / connectLanding / appResume | 已有 |
   | `settings.describe` | notification | 已有 |
   | `job.list` | notification / openSession | 已有 |
   | `session.modelCatalog` | notification / connectLanding | 判据 2 的五条事件 |
   | `permission.catalog` | notification / connectLanding | 判据 5 的 `permission-presets/catalog-changed` |
   | `agentPresets.list` | connectLanding | 判据 7:无事件 |
   | `workspace.list` | connectLanding | 判据 7:无事件(顺序变化由自己的写带回全集) |
   | `repo.info` | connectLanding | 判据 7:进程级事实 |

3. **首屏(决定 3):先等 rows,其余八项并行,并且"目录失败不许拦住落点"。**
   今天 `refreshSessions()` 是 **6 个 await 串行**(`:2865-2879`)—— 经中转时首屏凭空多
   6 个 RTT;而落点只需要 rows(行里的 `updatedAt`/`running`)。所以:
   - `landAfterConnect()` = `await rows` → `landOnSession()`;
   - 其余八项 `Future.wait` **并行**跑(首屏只多 1 个 RTT),失败各自留声;
   - **八项里任何一项失败都不影响落点**(今天 `refreshSessions` 内部都 catch,拆开后要
     显式保证:`landAfterConnect` 不因目录失败而跳过 `landOnSession`)。
   - **不把"等"收窄成"只等 rows 就完事"**:落点后如果目录还没到,新建 blank 会话的英雄页
     会先显示"拿不到模型"(它的 `currentModel` 回落到目录默认值)。并行已经拿掉了延迟,
     不需要再用"闪一下"换那几十毫秒。
4. **一次通知到一次重建(决定 4)**:四个目录各有 `onChange` → 今天首屏要通知 6 次
   (`HostCatalogs` 每项一次)。改成**一批只通知一次**(`Future.wait` 之后再 `notifyListeners`)。
   这不是请求数的问题,是 Flutter 侧整棵树重建 6 次的问题(启动那一下的可见卡顿)。
5. **重连必须重拉目录(决定 5)**:不缓存跨重连 —— 判据 6 就是 DSH 的做法,而理由在手机上
   更硬:通知只在服务态到达,**断开期间电脑上换了密钥 / 改了模型,手机收不到任何事件**,
   所以重连不重拉就永远错。这条同时否掉了我上一版想省的那 4 个请求:在弱网里它很诱人,
   但它牺牲的恰好是这条通道要保证的东西。

### 第 2 批(连接器侧,两条新触发源)

6. `session.modelCatalog`:听 `llm/adapters-updated`、`llm/models-updated`、
   `settings/document-updated`、`credentials/record-updated`、
   `credentials/reference-updated` → 发 `{keys:['session.modelCatalog']}`(宿主级,无 sid)。
   **不过是省请求,是补一个今天没有的能力**:电脑上加/换模型或改密钥后,手机的模型
   选择器不重连就看不到。
7. `permission.catalog`:听 `permission-presets/catalog-changed` → 发
   `{keys:['permission.catalog']}`。同理,今天是"部署改了预设表,手机要重连才看到"。

### 不做(每条都写清理由,不是忘了)

- **不给 `agentPresets.list` / `workspace.list` / `repo.info` 编触发源**:没有宿主事件
  (判据 7);编"每 N 秒"就是替宿主做决定。
- **不给 `session.row` 这种"只取一行"的新方法面**(见被否方案 2 的补充):真正的大头是
  `session.list` 的整包(本机 302 行),但**先量再说** —— 下一轮用连接器的字节数指标量
  一次"一次标题变更实际多少字节",再决定要不要窄口。
- **不把 `settings/document-updated` 按命名空间过滤**:过滤表就是第二份
  "哪些设置影响模型"的知识;DSH 浏览器侧同样不过滤(`service.ts:56`)。代价是设置页
  改一行会带来一次目录重取 —— 那是低频动作,且返回的是缓存内的一整包。

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
     DSH 有 `mergeOrderedBaseline` 与 `asOfSeq`,我们一条都没有)。
     **它真正省的是字节**(整包 302 行 vs 一行 JSON),不是往返数 —— 所以它属于"量完
     再议"的第二问(见文末),而不是这一轮该做的事:这一轮先把"一次拉太多"解决掉,
     字节问题要先用指标量出来,否则就是拿一个不可逆的协议决定去换一个还没量过的收益。
3. **保持现状**:把 7 个请求当成"一次完整快照刷新"。
   - 最强理由:零改动、行为最稳、没有 bootstrap/通知两条路径要防漂移。
   - 为何被否:它把"通知越准越好"这条投资浪费掉 —— 触发点精确到 `model/selection`,
     落地却是整表刷新;而且"自己的写 7 个往返"与用户点一下要等一次完整快照是同一笔账。
     逐条测试也不需要它:`host_state_test` 已经能断言"这条通知只发出哪些方法"。
4. **把目录缓存在内存里、跨重连保留**(只在失效事件 / 换电脑 / 冷启动时重拉)
   - 最强理由:弱网里手机一天闪断几十次,每次重连把 4 个目录重拉一遍是实打实的流量与
     电量;而目录变化极慢,看起来"重拉是浪费"。
   - 为何被否:**它牺牲的正是这条通道存在的理由**。`host` 通知只在服务态到达 ——
     断开期间在电脑上换了密钥、加了模型、改了预设表,手机**一条事件都收不到**;
     跨重连保留缓存就等于"用旧目录相信自己对",那比不刷新更糟(`ui-state.md` §1 的
     "不缓存过夜"是同一条判断的更粗版本)。DSH 自己也在 `connection/reset` 上重拉
     (判据 6),不是每代只拉一次。
5. **把首屏的 6 个串行 await 原样搬进 registry**(只拆登记、不动时序)
   - 最强理由:改动面最小,`landAfterConnect` 的行为与今天逐字相同,回归风险最低。
   - 为何被否:经中转/蜂窝时首屏凭空多 6 个 RTT(`app_model.dart:2865-2879` 是串行的),
     而落点其实只需要 rows。既然已经要把这份清单搬到一处,顺手把"串行等 6 件事"改成
     "并行等 1 轮"是同一处改动,不额外增加风险(每一件本来都自己 catch)。

## Consequences

- 收益:
  - 一条通知的往返从 **7~8 → 1~2**(切模型 = rows + projections;标题 = 同;权限 = projections);
    自己发起的写从 **7 → 1**。
  - 首屏:**6 个串行 await → 并行一轮**(经中转时少 5 个 RTT),且目录失败不再能拖住落点;
    目录到达时**只通知一次**,不再整棵树重建 6 次。
  - **补上两个今天没有的能力**:电脑上加/换模型或改密钥、改权限预设表后,手机不重连也能跟上。
  - 登记表成为"拉什么、何时拉"的唯一清单;`refreshSessions()` 这个名字消失,捆也就没了
    —— 以后想加"某个新快照",只能登记,不能偷偷塞进一个函数。
- 代价 1:**协议封闭集 +2 个 key**(`session.modelCatalog`、`permission.catalog`)⇒ 要同步
  契约 §5.9 的 key 表、连接器的 `HOST_STATE_KEYS`、app 的 `HostStateKey`(有跨端门禁
  `host_state_test`),并补"事件 → 通知"的连接器用例。
- 代价 2:**`connectLanding` 一列就是首屏行为**:好处是不会漂,坏处是改那一列等于改首屏,
  得靠落点测试兜(rows 必须在 `landOnSession()` 之前完成)。
- 代价 3:重新验证面变大 —— 首屏落点、回前台、自己的写、断连重连各看一遍(今天它们都在
  "7 请求"的同一条路上)。
- 代价 4:`session.modelCatalog` 要接 5 条宿主事件,其中 `credentials/*` 两条在连接器里
  **没有现成用法**(首次出现),要在 `index.ts` 新加两个 `ctx.effect`;
  `permission-presets/catalog-changed` 是第三条新监听。
- 代价 5:首屏从"串行等"改成"并行等"会改变**失败时的可见顺序**(以前第一个失败就停下,
  现在八个都会跑完再报第一个)。这更好(一次看到全部问题),但"只报第一个"这件事要写在
  测试里,免得以后有人以为是 bug。

## Testing

- `app/test/host_state_test.dart` 扩:
  - 每个新 key 至少一个触发点(已有机械判据);
  - **一条通知只发出该 key 的方法**:`{keys:['session.list']}` ⇒ 恰好 1 次 `client.call`,
    且方法名就是 `session.list`(现在是 7 次,这条会红);
  - `connectLanding` ⇒ 9 个方法各一次,且**并行发起**(断言"第一个请求返回前其余 8 个已发出");
  - `agentPresets.list` / `workspace.list` / `repo.info` **不接受 notification**
    (写进一条通知 ⇒ 零请求);`session.modelCatalog` / `permission.catalog` **接受**;
  - 目录失败不拖落点:`refreshHostCatalogs` 抛错时 `landAfterConnect` 仍然 `landOnSession`;
  - 一次批量只通知一次:`connectLanding` 期间 `notifyListeners` 的调用次数 = 1(计数桩)。
- `app/test/connect_landing_test.dart`:落点仍要等 rows(行里的 `updatedAt`/`running`),
  断言"落点前 rows 已到位、目录未跑完也能落点"。
- `connector/tests/host-state-notice.test.ts` 扩:五条目录事件 ⇒ `{keys:['session.modelCatalog']}`;
  `permission-presets/catalog-changed` ⇒ `{keys:['permission.catalog']}`;
  "`settings/document-updated` 同时命中 `settings.describe` 与 `session.modelCatalog`"。
- 真机(两条对照都必须是"改前红"):①在电脑上换密钥 / 改 `agent-default-model` →
  手机不重连打开模型选择器能看到新模型;②改权限预设表 → 手机不重连打开权限 sheet 能看到。

## 已经定掉的四件(原来列为 Open questions)

1. **`settings/document-updated` 不过滤命名空间**:过滤表是第二份"哪些设置影响
   模型/预设"的知识,漏一项就表现为"改了设置手机不跟";DSH 浏览器侧同样不过滤
   (`service.ts:56`)。低频动作 + 返回缓存内的一整包,这个价钱可以付。
2. **`permission.catalog` 有事件**(判据 5):`permission-presets/catalog-changed`。
   上一版写"只连上拉"是查漏,已改。
3. **首屏先等 rows、其余并行**(第 1 批的第 3 条):不采用"落点后再补目录"—— 那会让
   blank 会话的英雄页先显示"拿不到模型"。并行已经把延迟拿掉了。
4. **自己的写也走 registry**(第 1 批之外的补充):`selectModel` / `forkSession` /
   页面重试改成 `await triggered(ownWrite, sid:)`,**立即执行不压窗口**,方法名由测试断言。
   **保留"重拉行"这一步**(不用回执直接改本地行):行是电脑侧身份字段,
   `_touchSummary` 的注释已经写明"只换计数不重建整行";为了省 1 个请求去本地改写宿主
   派生字段,是把一条便宜的路换成一条会过期的路。

## 仍然不知道、且只能靠量的

- **`session.list` 的包有多大**:本机 302 行,一次标题变更就重拉整表。若实测单包达几十 KB
  且有明显比例来自与"这一行"无关的字段,下一步才谈"只取一行"(新增 `session.row` 方法面
  或行级推送)。**先量再改**:`connector` 已有 `connector.frames.outbound` 计数,
  需要的是字节数 —— 实施第 1 批时顺手加一个 `connector.bytes.outbound`(纯观测)。
- **中转计费与请求数的关系**:中转有按人流量额度(只计字节,不计请求数)。所以本次收益
  主要是**延迟与电量**,不是额度;别在文档里把它写成"省流量"。

## 落地时的事实（2026-11-01，第 1 批）

### 做完了什么

1. `AppModel.refreshSessions()` **从产品路径消失**：拆成 `refreshSessionRows()`（只做行）、
   `refreshHostCatalogs()`（模型 / 权限 / 预设 / `repo.info` 四件）；
   `settings.describe` 与 `workspace.list` 本来就是独立方法。没有留"全套再拉一次"的别名。
2. 登记表长到 **9 个 key**（`app/lib/data/host_state.dart`），`HostStateTrigger` 多一列
   `ownWrite`；连接器 `HOST_STATE_KEYS` 与契约 §5.9 的 key 表同批长到 9
   （`app/test/host_state_test.dart` 逐字比对两端）。
3. 首屏 = **一次并行批次**（`HostStateRefresher.startBatch`）：九项同时发起，`await` 的只有行；
   落点在行到达后立刻跑，目录失败不拦它（批次不抛，失败各自落 `lastError`）。
4. **一批只通知一次**：`AppModel.notifyListeners` 上开了一个闸（`_coalesced`）。
5. 自己的写走登记表的 `ownWrite` 列（`refreshAfterOwnWrite`）：`selectModel` /
   `forkSession` / `ui/chat_page.dart` 的重试。保留"重拉行"，不用回执改本地行。

### 与初稿的两处出入（初稿自身不自洽的地方，按判据改正）

- **`settings.describe` 与 `job.list` 也要 `connectLanding`。** 初稿的登记表给
  `settings.describe` 只写 `notification`、给 `job.list` 只写 `notification` / `openSession` ——
  那两格在"一条通知 = 一次 `refreshSessions()`"的旧形态下成立（设置面是被**顺带**拉的）。
  捆一拆，"顺带"这条路就没了：断开期间在电脑上改的设置，重连后**永远不会**被读回来
  （通知只在服务态到达）。所以九项都在 `connectLanding` 一列 —— 这也正是初稿
  「其余八项并行」与验收「9 个方法各一次」要求的口径。
- **通知闸罩住整批（含落点那一次）**，而不是只罩"其余八项"。只罩八项时实测通知 **8 次**
  （行先落地那一次 + 八项各自到达）；罩住整批才是**一次重建**。代价：落点的可见时刻
  = 目录到达（失败也会 flush，因为批次不抛）。首屏"加载态"那一次通知仍在闸外 ——
  它必须立刻画出转圈，否则界面停在上一屏。

### 新增的代价（实施才知道的）

- **代价 6（测试装配层）**：`app/test` 与 `app/integration_test` 里 **80 处**
  `await app.refreshSessions()` 其实是"把模型灌满"的夹具。拆开后改成
  `refreshSessionRows()`；另有两处**行为性**改写：`permission_test` 的两条
  （"目录随清单拉"→"目录自己拉"）、以及模型目录 / 权限目录 / 工作区分组那四个文件
  需要显式再拉那一份目录。夹具照着产品路径长，不是新增行为。
- **代价 7**：两条错误语义并存 —— `triggered()` 仍"抛第一条错误"（回前台 / 开会话用），
  `startBatch()` 不抛（首屏用，失败各自落 `lastError`）。判据写在
  `HostStateRefresher.startBatch` 的注释里，`host_state_test` 用"九项里任何一项抛错都不拦落点"
  钉住。
- **代价 8**：`ownWrite` 列只有 `session.list`。切模型的**投影**没有再登记一列 ——
  宿主会为同一件事发 `model/selection` 通知（合并后一个往返），再登记一列就是
  同一份快照拉两次。

### 门禁与实测

- `flutter analyze` 干净；`flutter test` **1628 项**（1619 + 新增 9 条）；
  `node app/tools/verify-platform-boundary.mjs` **673**；`dart analyze --fatal-infos` 干净；
  connector `pnpm exec tsc --noEmit` 干净 + `pnpm test` **794** 项。
- 真机（`d61cf622`，直连 8790）：改前一次 Web 侧切模型 = **8 个往返**（19 个入站帧），
  改后 = **2 个往返**；时延与字节数记在 `memory.md` 的当轮窗口。

## 第 2 批为什么留到下一轮

第 2 批接的是**连接器侧的宿主事件**（`llm/adapters-updated`、`llm/models-updated`、
`settings/document-updated`、`credentials/record-updated`、`credentials/reference-updated`、
`permission-presets/catalog-changed`），其中 `credentials` 那两条在连接器里**没有现成用法**
（首次出现，要新写两个 `ctx.effect`）。它与第 1 批没有共同风险面：第 1 批只改 app 侧
（+ 两张清单），第 2 批只改连接器；两批各自独立可验，合在一起只会让"哪一侧坏了"更难定位。
在那之前，`session.modelCatalog` / `permission.catalog` 的 `notification` 列在登记表里
**没有生产者**（只是已经接好了接收端：`host_state_test` 有一条用例证明这两个 key
收到通知就会重取；另外三个没有宿主事件的 key 则被另一条用例钉成"写进通知 ⇒ 零请求"）。

## 第 2 批已落地（2026-11-01，连接器侧）

### 做完了什么

1. **两个 key 接上了生产者，只改连接器一处**：协议、`HOST_STATE_KEYS`（九项与顺序都没动）、
   app 侧登记表与 `host_state_test` 一个字都没改。
   - `session.modelCatalog` ← `llm/adapters-updated`、`llm/models-updated`、
     `settings/document-updated`、`credentials/record-updated`、`credentials/reference-updated`；
   - `permission.catalog` ← `permission-presets/catalog-changed`。
2. **事件名逐个 grep 核实过**（不照抄初稿）：

   | 事件 | 声明 | emit 点 |
   |---|---|---|
   | `llm/adapters-updated` | `packages/llm/llm/src/types.ts:24` | `packages/llm/llm/src/index.ts:371`（注册表提交点） |
   | `llm/models-updated` | `packages/llm/llm/src/types.ts:30` | `packages/llm/llm-deepseek/src/host.ts:32` 等适配器的 `changed` |
   | `credentials/record-updated` | `packages/credentials/credentials/src/types.ts:99` | 同包 `src/index.ts:276` |
   | `credentials/reference-updated` | `packages/credentials/credentials/src/types.ts:87` | 同包 `src/index.ts:267` |
   | `settings/document-updated` | `packages/settings/settings/src/types.ts:75` | 同包 `src/index.ts:317,338` |
   | `permission-presets/catalog-changed` | `packages/interaction/permission-presets/src/types.ts:48` | 同包 `src/index.ts:461`（`registerAuto` 的注册 / 撤回） |

3. **触发点 → keys 的映射仍只在 `protocol/host-state.ts`**：
   `modelCatalogChangedNotice()` / `permissionCatalogChangedNotice()` 两个构造函数，
   外加四条事件的名单 `MODEL_CATALOG_HOST_EVENTS`。订阅与类型补充在
   `dsh/host-events.ts` 的 `onModelCatalogInvalidated` / `onPermissionCatalogChanged`
   （与 `dsh/jobs.ts` 的 `onJobsLifecycle` 同形：收 `ctx` 与 `notify`，返回注销函数），
   `index.ts` 只写两行 `ctx.effect(() => onXxx(ctx, notifyHostState))`。
4. **`settings/document-updated` 是一条事件命中两个 key**：`settingsUpdatedFor()` 现在
   返回 `{settings.describe, session.modelCatalog}`（ns 读得到）或
   `{session.modelCatalog}`（读不到），**永不为空**；`index.ts` 那条监听因此不再判
   `undefined`。`settings.describe` 那一半仍然只对 `READABLE_NAMESPACES` 发。

### 新增的代价（实施才知道的）

- **代价 9（类型面）**：`llm/*` 与 `permission-presets/catalog-changed` 三条事件的
  `Events` 补充进不了本仓的类型程序 —— 对应的包不是连接器的依赖
  （`@deepseek-ai/dsh-llm` / `dsh-permission-presets` 不在 `package.json`；`credentials/*`
  则能看见，因为 `@deepseek-ai/dsh-credentials` 是 devDependency）。做法是照
  `dsh/trajectory.ts:83` 的先例，在 `dsh/host-events.ts` 里补一段
  `declare module '@deepseek-ai/cordis'`，逐条给出处。**它是类型补充，不是第二份真值**：
  值仍由宿主发；将来把这些包加成依赖，同名同型的声明可以合并，删不删 `tsc` 都会说话。
- **代价 10（重新验证面）**：五条失效事件里，**只有 `settings/document-updated` 能在
  不重启宿主的提前下从 Web 侧触达**（写 `agent-default-model` 这一条设置）。
  `llm/*` 要加 / 删 provider 或改适配器配置、`credentials/*` 要改密钥 —— 都要动 profile
  配置或凭据，而重启会换 Web token 并断掉手机，等于把"不重连"这条验收前提拆了。
- **代价 11（每次可读设置变更多一个往返）**：写的是 `READABLE_NAMESPACES` 里的命名空间
  （`permission` / `agent-preset-registry` / `session-log-deepseek` / `ui-conversation`）时，
  一条事件会变成 **2 个请求**（`settings.describe` + `session.modelCatalog`）；写的是别的
  命名空间（如 `agent-default-model`）时只有 **1 个**（模型目录）。这是"不做命名空间过滤"
  直接换来的那笔钱，量在下面。

### 门禁与实测

- `cd connector && pnpm exec tsc --noEmit` 干净；`pnpm test` **794 → 796 项**
  （`tests/host-state-notice.test.ts` 加 2 条：模型目录的四条事件 + 订阅面与注销、
  权限预设目录的订阅；另把"设置文档变更"那条改写成"一条事件两个 key"）。
- **变异校验两处**（`git checkout` 不适用的场景 —— 工作树里本来就有本批改动，
  所以是"改→跑→改回"）：
  ① 把 `credentials/reference-updated` 从 `MODEL_CATALOG_HOST_EVENTS` 里删掉 →
  `pnpm exec tsx --test tests/host-state-notice.test.ts` **1 红**，恰好是"模型目录的四条宿主事件"那条；
  ② 把 `session.modelCatalog` 从 `settingsUpdatedFor` 的可读分支里去掉 → **1 红**，
  恰好是"`settings/document-updated` 同时命中两个 key"那条。
- 真机（`d61cf622`，profile `dsh-mobile-test`，直连 `0.0.0.0:8790`，App 未重装、未手动重连；
  宿主重启后由 App 自己重连，`connector.handshake.established` 1→2）：

  | 验收 | 红（改前 `lib/`，即 HEAD 的构建） | 绿（本批构建） |
  |---|---|---|
  | Web 侧写 `agent-default-model`（设置页同一条路径 `POST /api/settings/update`） | 宿主 `default` 变了（`deepseek-official/deepseek-flash` → `lightvela-free/spark-x2.6`），但 `connector.host.notices` **+0**、`connector.frames.inbound` **+0**：手机一个请求都没发 | `notices` **+1**、`inbound` **+3**、`bytes.outbound` **+3 826**（目录响应 ~2.7 KB） |
  | 30 ms 采样（写入时刻 → 通知 → 手机重取帧） | — | 三次实测：写入 **+0 ms** → notices **+107 / +108 / +84 ms** → 首个入站帧 **+141 / +217 / +328 ms**（同一秒内跟上；每次都是 notices +1、inbound +3、bytes +3 826） |
  | 权限预设目录 | **未验**（下方说明） | **未验** |
  | 一次标题变更的代价（Web 侧 `session/rename`，不发 prompt） | — | notices +1、入站 **+5 帧**、出站 **1 943 515 B**；拆开看：`host` 帧 **152 B**（+6 ms）、`session.projections` **~1 725 B**（+341 ms）、`session.list` 整表 **1 941 638 B**（+511 ms） |

### 两个实测才知道的事

1. **红的那一次，连 `settings.describe` 都没发**：`agent-default-model` 不在
   `READABLE_NAMESPACES` 里，旧代码对这条事件返回 `undefined`。也就是说这条设置写入
   在旧形态下**完全静默**（手机 0 个请求）—— 这正是"一条事件两个 key"要修的东西，
   也说明**不能用"notices 涨了没有"当红/绿判据**（旧形态下它压根不涨）。判据只能是
   "手机有没有重取帧"（`frames.inbound`）+ 目录内容。
2. **权限预设目录这条验不了**，不是漏了：`permission-presets/catalog-changed` 只由
   `registerAuto` 的注册 / 撤回发（`src/index.ts:461`），而那份预设表**在插件生命周期内
   固定**（`packages/interaction/permission-presets/README.md:135` 的原话：
   "The configured preset table is fixed for the plugin lifetime"）。live 改目录的唯一入口是
   `@deepseek-ai/dsh-auto-review` 挂上来调 `registerAuto`，而这份宿主（
   `pluginManager/listPlugins` 实测 **195 个插件**）里**没有**它。改 profile 的
   `cordis.patch.yml` 再重启是"改配置后重挂载"，不是"目录在跑动中变了"，而且重启会断手机 ——
   所以这条**如实记未验**，判据只剩单测（订阅面 + 通知形状）与"同一套 `notifyHostState` →
   `sendHostStateChanged` 出口已被模型目录那条真机验过"。补验的最小代价：装 auto-review
   （要一次重启）后把它启用 / 停用一次。

### 顺带：一次标题变更到底多少字节（笔记文末"先量再改"的答案）

**1.94 MB**（`connector.bytes.outbound` delta 1 943 515 B），其中 **99.9% 是 `session.list`
的整表响应**（1 941 638 B，本机 302+ 行）；真正与"这一行"有关的信息只有标题一个字段。
于是"要不要 `session.row` 这种窄口"的判据有了数字：**改一次标题 ≈ 1.9 MB，而一行 JSON
是 ~1 KB 量级**。这仍是一个不可逆的协议决定（备选方案 2 的两个障碍没变：与"只推提示不推
数据"冲突、且需要一套我们没有的行级合并语义），所以**本批只记数，不改协议**。
