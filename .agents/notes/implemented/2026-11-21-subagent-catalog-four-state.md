# Agent Note: 子智能体目录四态与"读取该谁发起"

Status: implemented

## Problem

**现象**（2026-11-21 真机，用户原话"子智能体怎么点击一直加载不出来"）：
从右上角连接状态 → 侧面板 → 「子智能体」页，面板永远显示「正在加载子智能体…」，
不报错、也没有「重试」。同一次会话里打开的那些会话有的正常、有的永久转圈。

**读代码定位到的三处相互作用**（都在生产路径上，且都只有一处能改）：

1. `AppModel.subagentCatalogOf` 对**从没读过**的会话返回
   `const SubagentCatalog.loading()`（`data/app_model.dart` 的原实现）。于是
   "没人发起过读"与"读取在飞"在界面上是同一句话，而 `isLoadingEmpty` 为真 ——
   界面画「正在加载」，实际零个在飞请求。
2. `_readProjections` 先置 `loading`，宿主回 `notModified` 时**直接 return**，
   不落状态。摘要由 `commitSnapshot` 在**上一次成功**之后提交，所以"读到过 → 一次失败
   （宿主 30 s 上限，`connector/src/dsh/projections.ts:90`）→ 再重试"这条路上，
   服务端答"没变"而手里已经空了，三态永久停在 `loading`；重试行只画在 `error` 态
   （`ui/subagent_tree.dart` 的 `_ErrorRow`），**连补救入口都没有**。
3. `HostStateRefresher` 的在飞表按 **key** 合流（`'session.projections'`），不带 `sid`：
   A 会话的一次慢读会把 B 会话的读取合流到它身上 —— B 那一次**请求根本不发**，
   `openSession(B)` 拿到的是 A 那次的结果。用户看到的就是"打开 B，B 的面板永久转圈"。

叠起来还有第四条：目录只在 `openSession` / 通知 / 回前台时读，而**面板被看见**不是触发点。
从连接操作直接进面板时，那次 `openSession` 早已发生（且可能读的是别的会话）。

## Decision

1. **`SubagentCatalog` 三态 → 四态**：新增 `never`（本进程没读过，**没有读取在飞**）。
   `subagentCatalogOf` 对没读过的会话返回 `never`。界面上 `never` 与 `loading` 都显示
   「正在加载子智能体…」（Web 把 `idle` 与 `loading` 当同一个可见状态，
   `SubagentHeaderLineage.tsx:465-467`），但**只有 `loading` 声称有请求在飞** ——
   这条区别是这次能被机械判定的原因。
2. **迁移收到一处**：目录的四态迁移搬进新模块 `data/subagent_catalog_cache.dart`
   （`begin` / `applied` / `keep` / `fail` / `parentOf`）。读取路径不许再直接拼
   `SubagentCatalog`。
3. **`notModified` 只在"手里真有这一包"时成立**。手里没有却收到"没变" ⇒ 落 `error`
   并留声（`StateError`），**不能**停在 `loading`。
4. **失败保留上一次的内容**（状态仍是 `ready`）：清空会把"读到过"改写成"从没读过"，
   而摘要还在服务端 —— 下一次带摘要的读取得到"没变"，这一屏就死在那里。清空只在
   手里本来没有内容时发生。
5. **在飞键改成 `(key, sid)`**（`HostStateRefresher.inFlightToken`）：会话级 key 的两次读
   是两个包。`inFlightOf(key)` 只对宿主级 key 有意义（今天只有 `repo.info` 用它）。
6. **新增触发列 `panelVisible`**：只挂 `session.projections`；由右抽屉「子智能体」页的
   三个"面板被看见"入口发起（`ChatPageState._refreshSubsMetrics` → `AppModel.focusView`）。
   不新开 AppModel 方法：`focusView` 加一个 `trigger` 具名参数（布尔参数会把两件事
   编码成 true/false，枚举才说得清是哪一屏）。

## Alternatives considered

1. **只给面板加一个"打开就 refreshSubagentCatalog"**（最小改动）
   - 最强理由：一处调用，十分钟能上。
   - 为何被否：绕开 `HostStateRefresher` 的合并与在飞去重 —— 同一会话的
     `openSession` 正在读时，面板再发一次就是两个应答乱序落地（投影包没有版本号）。
     而且它只治"没人发起"，不治 `notModified` 与按 key 合流这两条。
2. **`notModified` 时清掉摘要再重读一次**（把摘要当缓存失效）
   - 最强理由：语义最直接 —— "你说没变，那我忘掉，请给我正文"。
   - 为何被否：清摘要的入口在 `SyncClient`（`_snapshotDigests` 私有）。为它加一个成员
     就要改二十多个测试替身，而"手里没有内容"这个前提**本来就可以在调用方判定**
     （§Decision 3）。等真出现"摘要正确但内容必须丢弃"的第二个消费者再加。
3. **`never` 也在 UI 上画成"正在加载"**（不做四态）
   - 最强理由：用户看不出区别，少一个枚举值。
   - 为何被否：那就没法回答"到底有没有人在读"，这次的三处缺陷里有两处正是靠这条
     区别才能被用例钉住（见判据）。
4. **`panelVisible` 也挂 `job.list`**（顺手一起对齐）
   - 最强理由：任务面板被看见时那一份也可能旧。
   - 为何被否：`job.list` 的"被看见"是右抽屉的任务页，不是子智能体页；把两件事挂在
     同一个触发列上，等于给"面板"这个词两个含义。要做得先有 `jobsVisible`。

## Consequences

**收益**

- 面板永久转圈这一类**不可能再因为"没人发起读取"发生**：`never` 是显式状态，
  发起点只有一个触发列。
- `notModified` 与失败都不会再把四态留在 `loading`；界面上"转圈"只剩一种含义
  （真的有请求在飞）。
- A 会话的慢读不再吞掉 B 会话的读取。
- `app_model.dart` 因搬走两格（目录缓存 / 投影合并器）反而缩短了（尺寸棘轮只降不升，
  这次是被迫的结构性收益，不是顺手重构）。

**代价**

- `focusView` 从"轨迹页专属"变成"进入某一屏"的通用入口，多了一个具名参数；
  误用（对宿主级 key 传 `panelVisible`）在类型上不报错，靠一条机械测试钉住
  （"只有 `session.projections` 挂这一列"）。
- `never` 与 `loading` 在界面上不可区分 —— 这是有意保留 Web 的形态；区别只在数据层。
- 摘要/内容的寿命不一致这条**根因**仍在（`commitSnapshot` 之后内容被丢弃的路径
  还有别处）。这次只在目录这一格把后果挡住；`_compactIdleSessions` 若要放掉某个
  会话的快照，必须同时放掉它的摘要 —— 未做，记为已知缺口。
- 门禁：app 测试 **1973 → 1978**（+5 条新用例，1 条旧断言改判）、boundary **962 → 972**、
  size PASS（`app_model.dart` 从 5269 行预算内实测下降），`dart analyze --fatal-infos`
  0 issues。
- **0 个真机回合**（新用例与门禁都跑在本机；真机复验排在下一次装包）。

**判据**

- `app/test/subagent_catalog_state_test.dart` 5 条：
  ① 没读过是 `never` 且 `isLoadingEmpty` 为假；② `notModified` 而手里没有内容 ⇒
  `error` + `lastError`；③ 读到过之后一次失败 ⇒ 仍 `ready` 且内容留着；
  ④ A 的读取在飞时 B 的读取真的发出（记账替身按 `sid` 记请求）；
  ⑤ 登记表里 `panelVisible` 只挂 `session.projections`。
- `app/test/subagent_panel_test.dart` 的"没读过"一条**改判**：原来断言 `loading`，
  那正是第 1 处缺陷的形状；现在断言 `never` + `isLoadingEmpty == false`。
- 变异校验（各一次，确认恰好一条红，条数实测）：
  1. `inFlightToken` 改回"只按 key" ⇒ **1 条红**（④，报 `Actual: ['sid_A']` ——
     B 的请求确实没发）；
  2. `notModified` 分支改成无条件 `return reply` ⇒ **1 条红**（②，报
     `Actual: SubagentCatalogState.loading` —— 就是真机上那个永久转圈）。

代码入口回指：`data/subagent_catalog_cache.dart` 文件头、`data/host_state.dart` 的
`HostStateTrigger.panelVisible` 与 `inFlightToken`、`model/subagent.dart` 的
`SubagentCatalog` 文件头各有一行指向本篇。
