# `wire/rpc/` 的层形状：字段内核 + 一个面一个文件

- 日期：2026-10-25
- 状态：**已全部落地**（8 批、8 个提交；协议知识口禁实测 **0 处**，`BUDGET` 常量已删）
- 相关：`implemented/2026-10-25-wire-design-review.md`（五判据 / 被否方案）、
  `implemented/2026-10-25-wire-golden-and-session-list.md`（金样机器 + 第 0/1 批）

## Problem

第 0/1 批之后，`wire/rpc/` 里只有一个文件（`session.dart`），而剩下的 **25 个方法**还要搬。
如果每个方法都照着 `session.dart` 抄一遍手写读法，会出现第二套病：

- 必填/可选的判断散在 25 个文件里，各自记 `entry['x'] is Map ? … : null`；
- 同一个形态（`{sessions:[]}` / `{items:[]}` / `{jobs:[]}`、投影信封 vs 扁平 `values`）
  会被各写一遍，写错一处就是静默空值；
- 加一个方法要读三份先例、抄两种入口，**扩展成本随文件数线性上涨**。

## Decision

**一个面一个文件 + 字段读法只有一个实现 + 两种共享形态各一个入口。**

### 目录：`app/lib/wire/rpc/<面>.dart`

面 = 契约 §5.7 的服务段（**不是**一个方法一个文件）：

| 文件 | 方法 |
|---|---|
| `session.dart` | `session.list` / `create` / `select-model` / `cancel` / `updateQueue` / `prompt` / `projections` / `modelCatalog`（+ 连接层的 `page` / `refetch` 的形状）|
| `subagent.dart` | `subagent.prompt` |
| `workspace.dart` | `workspace.list` / `pin` / `unpin` / `archive` / `unarchive` / `insertSessionBefore` / `insertBefore` |
| `permission.dart` | `permission.catalog` / `permission.switch` |
| `settings.dart` | `settings.describe` / `settings.update` |
| `job.dart` | `job.list` / `kill` / `follow` / `unfollow` |
| `plugin.dart` | `plugin.list` / `listBundles` / `setEnabled` / `install` / `installStatus` / `cancelInstall` / `remove` |
| `file.dart` | `file.list` / `file.read` |
| `refs.dart` | `refs.files` / `refs.sessions` |
| `usage.dart` | `usage.summary` |
| `repo.dart` | `repo.info` |
| `endpoint.dart` | `endpoint.describe` |
| `preset.dart` | `agentPresets.list` |
| `command.dart` | `command.execute` |
| `interaction.dart` | `interaction.respond` |

每个方法在这个表里**恰好一行**，在对应文件里**恰好一处**方法名常量。
每个文件的结构固定：**发请求的 `load*`（收 `SyncClient`）+ 纯解码的 `read*`（收 `Object?`）**，
头注写清形状出处（`connector/src/...:行号`）与被否方案。

### 内核：`app/lib/wire/fields.dart`

三态（`WireOk` / `WireSkip` / `WireBad`）已有 `wire/reading.dart`；
`fields.dart` 只补**字段级**的三件事，且只实现一次：

| 语义 | 谁负责 | 计数 |
|---|---|---|
| 必填字段缺失 / 类型不对 | `WireFields.require*` 抛 `WireFieldError`，由 `readObject` 在**对象边界**转成 `WireBad` | 对象丢，计 1 |
| 可选字段**在但读不出** | `WireFields.optional*` 返回 `null` 并计数 | 字段降级，计 1 |
| 可选字段**缺席** | 同上返回 `null` | **不计**（生产侧按条件写，缺席正常）|

两种共享形态各一个入口，避免"谁读错了层"：

- `readObjectList(result, key: 'sessions'|'items'|'jobs'|'plugins'|'bundles'|'files'|…)`
  —— 信封坏 ⇒ 整天 `WireBad`；单条坏 ⇒ 丢那一条 + 计 1。
- `WireFields.envelopeValues('projections')`（**信封** `{kind, asOfSeq, values}`）
  与 `flatValues(raw)`（**扁平** `values`，`session.projections` 的应答）——
  同一个名字的两种形状，各自一个入口，用错在类型上就过不去。

### 为什么用"作用域内的异常"而不是 `WireReading` 串联

一个对象有 5~14 个必填字段；用 `WireReading` 串联要写 14 层 `switch`，而失败**必须成"整对象"一件事**。
所以 `require*` 在对象内部抛 `WireFieldError`，`readObject` 在那里**捕一次**转成 `WireBad`：
作用域明确、类型明确、出口唯一（`reading.dart` 的计数 + 打印）。这不是"宽 catch"，
旁证是它**不可能**吞掉 `ProtocolException` 或任何其它类型。

### 仍然不做（沿用设计评审的结论，不重新讨论）

- **codegen**：没有类型源（`MethodHandler` 回 `Promise<unknown>`）；
- **运行时 JSON Schema**：会成为第二份要同步的真值；
- **`RpcCaller` 回调**：`SyncClient` 端口本来就有，再造一个是重复抽象；
- **"方法名 → 唯一文件"名单表**：一条规则只能表达一个事实，41 个方法就是 41 条规则；
- **给"应答无人消费"的方法造假 decoder**：那等于给"我们校验过了"的假象。

## 批次与验收（一批一个提交）

| 批 | 范围 | 预算 | 状态 |
|---|---|---|---|
| 0 | 金样机器 + 预算门禁 | — | ✅ `5428fba` |
| 1 | `session.list`（含裸数组分支删除）| 39 → 38 | ✅ `e88d852` |
| A1 | 字段内核 + `session.create`/`select-model`/`cancel`/`updateQueue`/`prompt` + `subagent.prompt` + `session.modelCatalog` | 38 → 32 | ✅ |
| A2 | `session.projections`（14 个键 + 值对象）+ `session.page`/`refetch` 的形状（`wire/rpc/session_page.dart`）| 32 → 31 | ✅ |
| B1 | `workspace.*`（7 个，七种应答都是"分组 + 两列 id"或"整份顺序/集合"）| 31 → 24 | ✅ |
| B2 | `permission.*`(2) / `settings.*`(2) / `agentPresets.list` | 24 → 19 | ✅ |
| B3 | `repo.info`（`methods` 采样时归一掉）+ `endpoint.describe` | 19 → 17 | ✅ |
| C1 | `job.*`(4) / `file.*`(2) / `refs.*`(2) | 17 → 9 | ✅ |
| C2 | `plugin.*`(7) / `command.execute` / `usage.summary` / `interaction.respond` | 9 → **0**（删掉常量）| ✅ `e977c6f` |
| D | 金样覆盖全部已搬方法（`session.page`/`refetch` 也收，共 43 个）/ 两份笔记并入 `implemented/` / 记忆与工具收口 | — | ✅ |

每批的验收（四条同时成立）：**该批方法全部进金样且 App 侧 `badCount == 0`**、
**`data/`+`ui/` 里该批方法名归零**、**预算减到位**、**一次变异校验**（红的条数如实记录，
不追求"恰好 1"——好几个键本来就有 2~6 个真实消费者）。

**覆盖率是核过的**：`wire/rpc/*.dart` 里出现 42 个方法字面量，金样 43 个 ——
缺的那个是 `session.refetch`（它的方法名在 `core/sync_client_impl.dart`，因为走具名方法；
但**形状解码**在本层，金样照样收了它）。反向也没有多余：金样里除它以外的 42 个，
每一个都能在 `wire/rpc/` 里找到归属。

**2026-10-26 订正**：`session.page` / `session.refetch` 的调用已搬进
`wire/rpc/session_page.dart` 的 `loadSessionPage` / `loadRefetchedEvent`，
`wire/rpc/` 现在有 **43** 个方法字面量，与金样一比一；门禁
（`app/tools/verify-rpc-single-caller.mjs`）也改为扫 `app/lib` 全域（`wire/` 除外）。

## Consequences

- 收益：加一个方法的成本固定成"一个 `read*` + 一个 `load*` + 一条金样样本"
  ——不必再决定"必填还是可选"以外的任何结构问题（那一条本来就必须逐个方法想）。
- 收益：`{x: [...]}` 与信封/扁平这两种最容易读错层的形态，各自只有一个入口。
- 代价：多一层 `fields.dart`；对"只有两三个字段"的简单应答（如 `{accepted:true}`）
  来说它显得重，但那些方法本来就不造 decoder，所以不成立。
- 代价：`WireFields` 的 `require*` 用异常做控制流。它对**解码器内部**成立
  （作用域 10 行以内），但会让"这个函数会抛"不出现在签名上 ——
  约束是**只许在 `readObject` 的 `build` 里用**，`fields.dart` 与 family 文件头注各写了一遍。
- 风险：15 个文件里必然有重复的头注（形状出处）。这是有意的：
  出处必须与被约束的代码待在一起，收进一份总表就又变成"第二份真值"。

## 代码入口回指

- `app/lib/wire/fields.dart`（字段级语义的唯一实现）
- `app/lib/wire/rpc/session.dart`（面文件的范本：发请求与解码都在这里）
- `app/tools/verify-rpc-single-caller.mjs`（"还有几处漏在外面"的那个数）
