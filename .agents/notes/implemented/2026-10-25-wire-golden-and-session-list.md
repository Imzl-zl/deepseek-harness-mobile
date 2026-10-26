# 线上形状（RPC 应答）：金样机器 + `session.list` 的单读者

- 日期：2026-10-25
- 状态：已落地（第 0/1 批 + 后续 6 批，全部完成见
  `implemented/2026-10-25-wire-rpc-layer-layout.md`；2026-10-26 复核后：
  `app/lib`（`wire/` 外）零 `client.call<`、金样 **43** 个方法、`wire/rpc/` **43** 个方法字面量）
- 规格：`implemented/2026-10-25-wire-design-review.md`（本轮开工单
  `proposed/2026-10-25-wire-batch0-and-batch1-prompt.md`）
- 相关：`implemented/2026-10-25-event-wire-single-decoder.md`（事件面已落地，本篇沿用它的三态内核）、
  `implemented/2026-10-15-projections-envelope-must-be-unwrapped.md`（第二次事故的修法落在生产者侧）、
  `implemented/2026-10-24-plan-review-card-from-request.md`（第三次事故）、`memory.md` 教训第九条

## Problem

事件面收口之后，**RPC 应答面还是老样子**：`app/lib/data/app_model.dart` 里 41 个读取点、
104 个字面量字段，全是 `result is Map ? result['x'] : null`。形状错了不会有任何声音 ——
2026-10-15（投影信封装错层）与 2026-10-24（计划卡的 `arguments` 按对象读）都是这么过的。

规格笔记为此定了"金样"这条路，但第一版草案写的是**真样本快照**（桌面跑一次 App 抓 ~20 个方法的应答）。
这条路不成立，而且不成立的方式很阴：**真样本是一次性快照，连接器改了应答它不会变。**
于是用例永远绿 —— 与教训第九条（"用例喂的形状不是线上形状"）逐字同形，
只是把"手捏的形状"换成了"过期的真形状"。抓一份真样本还需要电脑侧起实例、配模型，
它把一道每天都要跑的门禁绑在了一次性的手工动作上。

**本轮先落机器，再搬第一个面。** 没有金样，后面七批的"验收"都只是"用例绿"，
而那正是三次事故里全绿的那个绿。

## Decision

**形状的真值在生产者（连接器），判据是一份由连接器的测试从真实 handler 生成、深比较守住的
金样；App 的用例读同一份文件。**

准入门槛（可机械判定）：

1. **金样按"方法名 → 样本数组"**，`connector/tests/fixtures/wire-shapes.json` 入库；
   数组是必须的 —— 同一个名字在线上可能有**两种形状**（见下条）。
2. **比较必须在"线上那一层"**：比 `JSON.parse(JSON.stringify(result))`，不比 JS 对象 ——
   `{a: undefined}` 与 `{}` 在 JS 里不相等、在线上是同一件事。
3. **只有 `UPDATE_WIRE_SHAPES=1` 才写盘**（快照测试的老做法），平时只比较；
   键集合与 `SAMPLES` 对不上、某方法一条样本都没有 ⇒ 红（缩水会让 App 侧断言在空集上全绿）。
4. **App 侧一条"金样在就不会空跑"的用例**：文件缺失**直接 `fail`，不许 `skip`**。
5. **采样必须确定性**：假 id 走 `tests/support/fake-aliases.ts` 的定值表，行里没有时间戳、
   没有随机值；另有一条"采两遍必须一模一样"的用例把它按住。

本轮收进金样的两个方法，**故意是同一个名字的两种形状**：

| 位置 | 形状 | 出处 |
|---|---|---|
| `session.list` 行里的 `.projections` | **完整信封** `{kind, asOfSeq, values}` | `connector/src/dsh/sessions.ts:333-341`、`handlers.ts:766-768` |
| `session.projections` 的**应答** | **扁平 `values`**（无信封、永不 `null`，`null` → `{}`） | `connector/src/dsh/projections.ts:68-72`、`:94` |

两个决定各自都有理由（"拆信封"是第二次事故的修法；"原样透传不挑键"是
`dsh/sessions.ts:155-161` 的注释），合起来就是一个 50% 会踩的坑，而踩错的表现为**静默空值**。
单靠"每个方法一个 decoder"抓不到它 —— 能抓住它的唯一形态是**金样里两种形状并存，谁读错谁红**。

## Alternatives considered

1. **真样本快照（第一版草案的路）**
   - 最强的理由：零新增测试代码 —— 抓一次就是一门外加的真实形状，比手写用例可信。
   - 为何被否：**它不随实现变化**。连接器改了应答，用例照旧绿，而那正是三次事故里的那个绿。
     另外它把门禁绑在"电脑侧起实例 + 配模型"的一次性手工动作上，每天跑不了。
2. **运行时 schema 校验（每个方法一张 JSON Schema）**
   - 最强的理由：形状错误在**进入系统之前**就被拦住，消费端可以完全不设防。
   - 为何被否：schema 与 decoder 是两份要同步的真值，而我们需要的恰恰不是"通用校验"，
     是"这 46 个方法的字段各是什么类型、从哪一层取"。它可行的形态就是本篇的机制（用生产输出当金样），
     不是手写 schema。
3. **从连接器 TS 类型 codegen 出 Dart**
   - 最强的理由：形状永远与生产者一致，漂移在**编译期**响，比任何回放都强。
   - 为何被否（**今天不可选，不是不好**）：没有类型源 —— `MethodHandler` 返回 `Promise<unknown>`
     （`connector/src/protocol/methods.ts:280-283`），`METHODS` 只是 49 个字符串。
     要 codegen 得先写 46 个应答类型，那就是"把形状责任推回连接器"，成本是金样的几十倍。
     触发条件写在规格笔记的「仍未决」第 4 条。
4. **把金样放进 `protocol/`**
   - 最强的理由：本仓已经有 `protocol/fixtures`，看起来"线上东西都归那儿"。
   - 为何被否：`protocol/` 是三端协议向量（帧、封箱、恢复），生成者是连接器自己的实现，
     两边性质不同。金样的生成者是**连接器测试**，就跟连接器测试放一起。
5. **金样顺带收 `repo.info`**
   - 最强的理由：它是最常被手机读的方法之一（能力位 + 方法表）。
   - 为何被否：它的 `methods` 是 `Object.keys(handlers).sort()`（`connector/src/handlers.ts:1519`），
     **加任何方法它都会变**，会为与形状无关的原因常年红。要收它得先归一成"方法条数"，留到第 4 批。

## Consequences

- 收益：漂移在**改连接器的那个提交**里就能被看见（金样 diff + App 回放用例），不用等真机 ——
  这是三次事故里唯一真正缺的一环。
- 收益：`session.list` 的 4 种行（普通 / 子会话 / 冷行 / 完整信封）现在是**一份共享的假行**
  （`connector/tests/support/fixture-handlers.ts`），连接级用例与金样用的是同一份，
  不会再出现"用例喂一种形状、金样另一种"。
- 代价：**引入两个工程之间的测试耦合**。`app/test/wire_shapes_replay_test.dart` 读
  `../connector/tests/fixtures/wire-shapes.json`。先例已存在但方向相反
  （`connector/tests/error-table-parity.test.ts` 读 App 的 `lib/core/errors.dart`），所以不是新范式，是新的方向。
  该文件缺失时**必须 fail**（`skip` 会让门禁静默退化成空跑）。
- 代价：改连接器应答变成了一件"会红两个工程"的事。这是有意的摩擦：
  确认无误后 `UPDATE_WIRE_SHAPES=1` 重生成，并**同一批**改 App 的解码。
- 代价：假行从 1 条涨到 4 条，`connection-methods.test.ts` 里有几处按旧装置写的断言要跟着改
  （`session.list` 的行数、`repo.info.methods` 因为多给了 `models` / `projections` 两个面而多三条）。
  这些是**断言跟着装置走**，不是放宽。
- **未做**：`session.projections` 的 14 个键本轮不解（第 3 批），本轮只是把它的应答收进金样 ——
  它在这里的作用是"证明同一个名字有两种形状"，不是"读它"。

## 判据（第 0 批）

- `connector`：**657 → 660**（`tests/wire-shapes.test.ts` 三条：键集合 / 逐字深比较 / 采样确定性）。
  `pnpm exec tsc --noEmit` 0。
- `flutter test`：**1241 → 1243**（`test/wire_shapes_replay_test.dart` 两条：键不缺 / 每条样本是对象且不空）。
- **变异校验**：把金样里 `session.list` 第一行的 `running` 改成字符串 `"true"`
  ⇒ 连接器**恰好 1 条红**（`线上形状与金样逐字一致`），diff 点名 `running: 'true'` vs `false`；
  改回来即绿。这证明金样不是恒真的。
- `node app/tools/verify-rpc-single-caller.mjs` 新增：预算 **39** ⇒ PASS 并静默；
  临时探针（往 `app/lib/data/preview_data.dart` 塞一处 `client.call<`）⇒ FAIL 并逐行报出 40 个位置。
- `verify-tool-paths.mjs`：**23 → 24** 个脚本（新脚本的路径全部相对仓库根，无盘符字面量）。
- `verify-platform-boundary.mjs` **509** 持平。

## 代码入口回指

- `connector/tests/wire-shapes.test.ts`（金样生成与深比较）
- `connector/tests/support/fixture-handlers.ts`（连接级用例与金样共用的一份假行）
- `connector/tests/fixtures/wire-shapes.json`（金样本体）
- `app/test/wire_shapes_replay_test.dart`（App 侧回放：文件缺失即 fail）
- `app/tools/verify-rpc-single-caller.mjs`（"协议知识还有几处漏在 `wire/` 外面"的那个数）
- `app/lib/wire/rpc/session.dart`（第 1 批：`session.list` 的唯一发请求与唯一解码）
- `app/lib/data/app_model.dart` 的 `_fetchSessionRows`（唯一的调用点，只剩一行委派）

---

## 第 1 批：`session.list` 的单读者

### Problem

`session.list` 的解析在 `app/lib/data/app_model.dart` 里摊成了五个函数
（`_parseSessionList` 79 行 + `_titleHintOf` + `_projectionValueOf` + `_modelSelectionOf` +
`_parseModelRef`），还有一条"裸数组也认"的分支。两个后果：

1. **协议知识留在 `data/`**：方法名、参数形状、应答字段三样都在 `wire/` 外面，
   而"还有几处漏在外面"没有数字可看 —— 搬走解码却留着 `client.call<…>('session.list')`
   与搬走整件事，在评审眼里长得一样。
2. **形状错的三种表现全是静默的**：缺 `running` 就 `== true` ⇒ `false`（把"读不到"
   说成"没在跑"）；`projections` 认不出 ⇒ 标题/模型/时长/token 全空；裸数组 ⇒
   一次**成功的空清单**。第三种最坏：它让"电脑上没有会话"与"我们没看懂回复"同形。

### Decision

**`session.list` 的方法名、参数形状、应答字段全部收进 `app/lib/wire/rpc/session.dart`；
调用点只剩一行委派；预算 39 → 38。**

准入门槛（可机械判定）：

1. **`data/` 与 `ui/` 里 `client.call<` 的处数 == 预算**（39 → 38 → … → 0）。
   这一批落地的就是那**一处**：`_fetchSessionRows` 改成 `loadSessionList(client)`。
2. **必填 / 可选看生产方式，不看名字**：`handlers.ts:740-744` **无条件写出**的
   `sid` / `updatedAt` / `running` / `blank` / `subagent` 缺失 ⇒ 整行丢 + 计数 1；
   被 `...(cond ? {} : …)` 包住的 `parentSessionId` / `cwd` / `model` / `projections`
   缺失 ⇒ `null`（正常），**在但读不出**才降级 + 计数 1。
3. **信封错与行级问题分档**：`{sessions: [...]}` 都没了 ⇒ 外层 `WireBad`；
   一条坏行只丢那一行 —— 丢整行会让会话从列表消失，比空标题坏得多。
4. **旧读法整段消失**：`_parseSessionList` / `_titleHintOf` / `_projectionValueOf` /
   `_modelSelectionOf` / `_parseModelRef` 与裸数组分支一起删
   （函数体 107 行，连头注一起 **净 −146 行**：`git diff --numstat` 是 `+8 / −154`）。
5. **产出已有模型类** `SessionSummary`，不新造 DTO；`pendingCount` / `itemCount`
   仍由 `_applySessionList` 本地补。

关于两处细节（都是"如实记账"而不是"放宽"）：

- **`cwd` 的空串不计数**：连接器原样透传宿主的 `cwd`（`handlers.ts:760`），
  空串只可能意味着"没有目录"，不是漂移。**`parentSessionId` 的空串计数**：
  连接器显式不为 `undefined` / 空串建别名（`handlers.ts:728-736`），所以空串只可能来自漂移。
  两个键的处理**故意不同**，理由都写在各自的函数头注里。
- **`values` 里我们还没消费的键不计数**：金样的"普通行"就放了一个 `agentPreset`
  —— 一个会话行的投影里有很多手机暂时不读的键，把它们当漂移会天天红。

### Alternatives considered

1. **只搬解码，把 `client.call` 留在 `app_model.dart`**
   - 最强的理由：改动最小 —— 调用点不动，鉴权/请求号/错误分类那条既有链路完全不受影响。
   - 为何被否：方法名与参数形状**仍然是 `data/` 的知识**，预算降不下来 ⇒ 这一类门禁
     对这一批完全无效，下一批还会以同样的理由把调用留在原地。搬调用的理由是
     "`data/` 不该知道方法名与参数形状"，不是为了迁就一个 grep。
2. **`session.page` / `session.refetch` 一起搬（一次把会话面搬完）**
   - 最强的理由：这三个方法同属"会话怎么读"，分两批会让 `wire/rpc/session.dart` 先长一半。
   - 为何被否：它们的形状读取在**连接层**（`core/sync_client_impl.dart:957` / `:990-1016` /
     `:1024` / `:1038-1052`），而 `SessionPage` 要参与 `await refetch` 补取 ——
     一个纯 decoder 不能 `await`。这需要两字段的中间结构（`SessionPageWire` + 判别联合），
     是第 2 批；塞进这一批会让"一个方法一个文件"的边界立刻糊掉。
3. **新造一个 wire DTO，不复用 `SessionSummary`**
   - 最强的理由：wire 形状与界面模型解耦，金样变了只改 DTO，界面层不动。
   - 为何被否：`pendingCount` / `itemCount` 是**本地派生**（跨请求汇总），不在线上；
     新 DTO 会引出两个形状几乎相同、差两个字段的类型，界面层还要再映射一次 ——
     而 `chat_item.dart` 不 import `wire/`，`wire → model` 本来就是单向的，不会成环。
4. **保留裸数组分支（"早期的假客户端与将来的简写"）**
   - 最强的理由：兼容性 —— 假客户端与"将来也许更简单的形状"都能跑。
   - 为何被否：连接器**从来只回 `{sessions: [...]}`**（`handlers.ts:738`）；
     留着它"认不出必须留声"永远不成立，而代价是"空清单"与"没看懂"同形。
     旧用例 `裸数组也认…` 因此改成**反向断言**（空列表 + `badCount == 1`）——
     这是把"容忍假客户端"换成"钉线上形状"，不是删断言。

### Consequences

- 收益：`app_model.dart` **净 −146 行**（`git diff --numstat`：`+8 / −154`；
  `_parseSessionList` 79 行 + 5 个辅助 30 行 + 各自的头注），
  方法名只剩 `wire/rpc/session.dart` 一处；形状错从"静默空值"变成"计数 + 一行打印"。
- 收益：**"可选键"第一次真的被测到**：金样的四行覆盖 `parentSessionId` / `cwd` / `model` /
  `projections` 各"有与没有"，把任何一个当必填都会红。
- 代价：**`wire/` 多了一条指向 `core/` 的边**（`wire/rpc/session.dart` 直接收
  `SyncClient` 端口）。方向是对的（适配器依赖端口），但"`wire/` 只依赖 `reading.dart`"
  这个纯度说法从此不成立，如实记账。
- 代价：**"可选键在但读不出"会计数**，于是同一个"漂移"数字里混着两种严重程度
  （行丢掉 vs 字段降级）。这是有意的：两者都需要有人看一眼，而分开计数要多一套状态。
  真需要分桶时再加维度（`WireDiagnostics` 是进程级计数，见 `wire/reading.dart`）。
- 代价：**迁移面不小** —— 恒发键变成必填之后，15 个测试文件里手写的会话行都得补齐，
  另外 `session_list_wiring_test.dart` 里"老连接器不发 blank 时不能默认成 true"那条前提
  被证明是错的（连接器**无条件**写 `blank`），已改成"缺 `blank` ⇒ 整行丢 + 计数 1"。
  这正是"钉线上形状"的直接代价，也正是不再容忍假客户端形状的那部分。

### 判据（第 1 批）

- `flutter test`：**1243 → 1251**。新增/改动的用例：
  - `test/wire_shapes_replay_test.dart` 由 2 条涨到 9 条：金样的**四种行各一条**
    （名字与期望值全部从金样长出来）、可选键覆盖两侧的守卫、缺 `sid` ⇒ 整行丢 + 计数 1、
    `values` 不是映射 ⇒ 该行仍 `WireOk` + 四个投影字段降级 + 计数 1。
  - `test/session_list_wiring_test.dart`：裸数组改成反向断言；"老连接器默认 blank"
    换成"缺恒发键 ⇒ 整行丢 + 计数 1"（20 条，原 19）。
- 预算：**39 → 38**（`app/tools/verify-rpc-single-caller.mjs` 的 `BUDGET`），PASS 且静默。
  反向校验：把常量写成 39 ⇒ FAIL 并逐行报出 38 个位置（说明它真的在比，不是恒真）。
- `verify-platform-boundary.mjs`：**509 → 512**（`app/lib` 多一个 Dart 文件：112 → 113）。
- `connector`：**660** 不变（本批只改了金样里"普通行"的投影值：去掉 `title`，
  因为未命名是正常态，且这样"标题"这条变异才恰好只红一行）。
- **变异校验**：把 decoder 里的 `values['title']` 改成 `values['tittle']`
  ⇒ 金样回放里**恰好 1 条红**（第 4 行 —— 金样里唯一带标题的那一行）；
  全仓共 7 条红（另外 6 条是别的套件自己断言了标题的用例，说明变异打在真实读法上）。
  改回来即绿。
- `dart analyze --fatal-infos` 0、`dart format` 0。

### 代码入口回指（第 1 批）

- `app/lib/wire/rpc/session.dart`（头注写了形状出处、必填/可选的分界、信封与扁平的区别）
- `app/lib/data/app_model.dart` 的 `_fetchSessionRows`（唯一调用点，一行委派）
- `app/tools/verify-rpc-single-caller.mjs`（那个从 39 起、终态 0 的预算）

---

## 同日实测：真实 DSH 会话清单走完生产链（0 个模型请求）

不是替身：数据取自一棵**活的隔离实例**，映射走的是仓库里那份生产代码。

做法（可复现，约 5 分钟）：

1. `$env:DSH_HOME='D:\tmp\dsh-e2e'` + `dsh --profile mobile-e2e --port 63900 --no-open`；
2. 带 token 打开 `http://127.0.0.1:63900/`，在**页面里**（cookie 已就位）POST `/api/session/list`，
   body 是 `{"type":"client-request","rpcId":"…","method":"session/list","payload":{"args":{"_request":{}}}}`。
   两个坑：**服务键是 `session`**（写 `sessionController` / `sessions` 都是 404）；
   **args 必须带 `_request`**（少了回 `gateway/arguments-invalid: missing "_request"`）；
3. 拿到的 `{items:[…]}` ⇒ `createSessionsAdapter`（生产适配器）⇒ `createHandlers(...)['session.list']`
   （生产 handler）⇒ 这就是手机真正会收到的那份载荷；
4. 那份载荷交给 App 的 `readSessionList`。

结果（2026-10-25 20:31，20 条真实会话）：

| 环节 | 结果 |
|---|---|
| DSH 原始 items | 20 条。行级键 = `sessionId` / `updatedAt` / `agentAvailable` / `formatStatus` / `running` / `blank` / `cwd` / `projections`（子会话另加 `parentSessionId` / `origin`）|
| 适配器 → 行 | 20 → 20（一行没丢）|
| 过线键出现次数 | `sid` / `updatedAt` / `running` / `blank` / `subagent` / `cwd` / `projections` **各 20**；`parentSessionId` **恰好 6**（= 6 个子会话）；`model` **0** |
| `projections` 形状 | 20 条**全是信封** `{kind, asOfSeq, values}`（不是扁平 map）|
| App 解码 | **20/20 `WireOk`，`badCount == 0`，零出声**；子会话父级别名正确（`sid_9a2bd3d9 → sid_30fd5a9c`）；`subagentTiming` 真值 115204 / 19887 / 28687 / 40061 / 49196 / 102090 ms；`tokenUsage` 真值；3 条无标题会话读成 `""` ⇒ 显示「未命名」|

三件事因此从"设计假设"变成"实测过"：

- 五个恒发键**确实**在每条真行里都有 —— 把它们当必填不会丢真数据；
- `projections` **确实是信封** —— 这正是第 1 批（行）与第 3 批（扁平 `values`）的分界；
- `model` **确实**可以整键缺席（这次 20 条全缺：隔离实例里 `agentAvailable` 全是 false），
  而 `values.modelSelection` 照样给出 `auto` —— "冷会话/子会话靠投影提示"那条路的实证。

**这次没覆盖**：① 真机上的渲染（本次只验解码层）；② `model` 键**出现**的那一半
（要一个活 agent，即一次模型请求，本轮不做）；③ 连接器那层以下的 DSH 适配细节
（`dsh/sessions.ts` 的映射只有手写假输入兜着 —— 这次的真输入只喂到了适配器入口，
`real-session-summaries.json` 那类固化没有做）。

**是否固化**：这次是手工实测，脚本在 `D:\tmp\capture-wire.mts`（**不入库**）。
把它固化成"真实清单进金样的第二条样本"是可行的下一步，但那要新增一条生成路径、
等于给金样多一个输入源，得单独决定 —— 本轮**没做**。


