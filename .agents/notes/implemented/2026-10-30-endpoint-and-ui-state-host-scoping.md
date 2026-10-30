# Agent Note: 端点身份、UI 状态与电脑名都带上归属（`hostId`）

Status: implemented

实现 `proposed/2026-10-29-one-phone-many-computers.md` 的落地顺序第 1 步（归属）。
四步里只有这一步是纯手机侧逻辑，不改 UI 形状。

## Problem

一台手机要配多台电脑时，三处状态都只按"一个地址 / 一段全局键"记账，换电脑就会串或丢：

1. **端点身份是 url**（`app/lib/core/endpoint.dart` 的 `Endpoint.id => url`）。
   `hidden` / `succeeded` / 拨号记录 / "记住的那条" 全按它记。两台电脑先后用
   同一个局域网地址（`192.168.x.y:8790`）时，它们是**同一条记录**：
   后者的"成功过"会给前者的死地址续命（剪枝规则是"成功过的永不删"），
   "记住的那条"也会指向不属于当前电脑的地址。
2. **UI 状态是一段全局 `host.*`**（`app/lib/data/ui_state.dart`）。切到另一台电脑后，
   `pruneSessions` 会拿**那次**的会话清单去剪页签/草稿 —— 剪掉的其实是另一台电脑的记忆；
   而"重新配对"干脆整段清空。两台电脑的会话 id 各自独立，这不可能是同一个事实。
3. **`repo.info` 没有电脑名**。多机之后界面至少要能说清"现在连的是哪台"，
   而连接器手里已经有 `os.hostname()`。

## Decision

### 1. 端点身份 = 归属 + 地址

- `Endpoint.id = endpointIdOf(url, hostId:)`：有归属时 `hostId|url`，没有归属时退回 `url`
  （单测与未装配身份的路径行为不变）。`==` / `hashCode` 同样按 id。
- `hidden` / `succeeded` / `attempts` / `remembered` 因此**自动按电脑分桶**，
  不需要四份平行表。
- "记住的那条"从 **url 改成 id**（`rememberedEndpointUrl` → `rememberedEndpointId`）：
  存 url 在多机下一定会串。落盘键名仍是 `remembered`，读取端按"带不带 `://`"
  区分旧形状（url）与新形状（id）。
- 配对种子的端点（`app/lib/main.dart` 的 `_onPaired`）也盖上 `hostId`：否则连接器
  第一次自报同一条地址时 id 对不上，会追加出一条重复记录。

### 2. 读取时补齐归属（不另写迁移脚本）

`app/lib/platform/pairing_store.dart` 的 `load()` 知道"这份凭据是哪台电脑的"
（`pcSignPub`），于是：

- 表里没有 `hostId` 的条目按它盖章（升级前落的 / 配对种子都归它）；
- `remembered` / `hidden` / `succeeded` 里的裸 url 按同一台电脑补前缀。

迁移是**读时**做的，下一次 `saveEndpoints` / `saveEndpointMeta` 自然落成新形状。
理由：旧数据只可能属于当前这份凭据的那台电脑，答案在读取点唯一可得。

### 3. `host.*` 按电脑分桶

- 键变成 `host.<hostId>.<field>`（`UiStateStore` 的 `_hostKey` / `_sessionKey`）；
  **没有电脑身份时**退回旧的平铺 `host.<field>`（未配对 / 单测没装配 `hostIdOf`）。
- `open()` 在拿到身份后把平铺键**一次性**搬进当前桶：桶里已有的键不覆盖（半迁移时桶优先），
  搬完逐个删旧键 —— 所以第二次 `open()` 一次写都不产生。
- `pruneSessions(liveSids)` **只剪当前桶**：`liveSids` 来自当前那台电脑的清单。
- `clearHostScope()` 只删**当前桶**（"忘掉这一台"）；`_onPaired` **不再调用它** ——
  分桶已经把两台电脑分开，配对成功不该再清一次（否则重新配对 = 丢草稿）。
  并发的分桶位于同一次 `open()`，`AppModel` 换电脑仍是换一个实例。

### 4. `repo.info.hostName` 是展示值

- 连接器 `HandlerDeps.hostName?: () => string`（`connector/src/handlers.ts`），
  装配层给 `() => os.hostname()`；取不到或为空就**不报这个键**。
- 手机侧解码成 `RepoInfoWire.hostName` / `AppModel.hostName`（`null` = 没读到）。
- **不进握手 transcript**：名字可改，进去就等于"改个名字要重新配对"。
  手机侧改名（`host.<hostId>.name`）与展示留给切换那一步。

准入门槛（可机械判定，均已跑过）：

1. **同一个 url 属于两台电脑 = 两条记录**：`id` 不同、不相等；
   A 成功过后切到 B，B 的 `remembered` 为空；B 那条没成功过 + 拨过失败 + 不再被自报 ⇒ 被剪掉
   （`app/test/endpoint_book_test.dart` 的「同一 URL 属于两台电脑」）。
2. **冷却按 id 查表**：带归属的端点用裸 url 当 `attempts` 键会查不到冷却
   （`app/test/endpoint_switching_test.dart` 的「别的电脑报的排后面」用它当判据）。
3. **桶隔离**：A 的 last_session / 抽屉折叠 / 页签 / 草稿在 B 上读不到，切回 A 全在；
   B 的 `pruneSessions` 不删 A 的键（`app/test/ui_state_test.dart` 的「按电脑分桶」两组）。
4. **迁移幂等，判据是写次数**：旧平铺键迁进桶后旧键消失；同一个 `open()` 再来一次
   `prefs.writes` 不变（同文件「旧的平铺键一次性迁进当前桶」）。
5. **`clearHostScope` 只删当前桶**：`host.pc-B.*` 原样保留（同文件「只删当前桶」）。
6. **`repo.info.hostName` 三种态**：给了就报、空串不报、没有依赖不报
   （`connector/tests/handlers.test.ts`）；App 解码对金样逐字一致，空串 ⇒ `null`
   （`app/test/wire_shapes_replay_test.dart`）。
7. **金样同批重生成**：`repo.info` 多一格（`connector/tests/fixtures/wire-shapes.json`），
   `UPDATE_WIRE_SHAPES=1` 重采；采样用的名字是定值 `build-machine`，
   不能拿真 `os.hostname()`（否则金样跟着机器变）。

变异校验（一次性，条数写进提交）：
`Endpoint.id` 改回 `url` → App 侧「同一 URL 属于两台电脑」与「桶」相关用例红；
`_migrateLegacyHostKeys` 去掉删旧键那一步 → 迁移幂等那条红（写次数变多）；
`hostName` 守卫改成无条件报 → 连接器「空串不报」那条红。

## Alternatives considered

1. **只把三份元数据（remembered / hidden / succeeded）按 host 分桶，`Endpoint.id` 仍用 url**
   - 最强的理由：端点表本身的形状不动，改动集中在 `EndpointMeta` 的序列化上，风险最小。
   - 为何被否：表里同一条记录仍然只能有一个 `hostId` —— 两台电脑共用地址时，
     合并时后盖章者覆盖前者，"换了一台电脑"就判不出来。身份不带上归属，
     剪枝、拨号记录、手填标记全都要再分一遍，等于四张平行表。
2. **`remembered` 继续存 url，另存一个 `rememberedHostId`**
   - 最强的理由：字段语义直观，旧数据的迁移只是补一个字符串，不涉及端点表。
   - 为何被否：它是**单槽**记忆 —— 切到 B 会把 A 的"记住的那条"覆盖掉，
     切回 A 就少了第一优先。存 id 之后槽本身自带归属，切走不丢。
3. **`_onPaired` 继续调用 `clearHostUiState()`（配对成功就清当前桶）**
   - 最强的理由：保持"重新配对 = 从头开始"的既有直觉，避免旧草稿出现在新身份下。
   - 为何被否：分桶之后清的是**新电脑**那个桶（刚读进来的），
     等于同一台电脑重配一次就丢草稿；而换另一台电脑本来就落到新桶。
     "忘掉这一台"应是用户动作（与凭据那一步的 `clear` / `clearAll` 拆分同一条）。
4. **把 `hostName` 放进握手 transcript（或放进配对载荷）**
   - 最强的理由：连接那一刻两端就知道名字，不必等一次 `repo.info` 往返。
   - 为何被否：transcript 参与密钥派生与验签，改一个展示值就变成"必须重新配对"；
     而名字本来就允许手机侧改名、允许重名，它不配进身份面。
5. **`hostName` 写进 `endpoint.describe`（端点自报）**
   - 最强的理由：那条应答本来就随连接刷新，手机已经在读。
   - 为何被否：端点面回答的是"从哪些地址能拨到这台电脑"，名字与地址无关；
     而且没有直连监听面时那条方法按能力位不挂，名字会跟着消失。
6. **为旧落盘写一个离线迁移（改 schema 版本 + 数据迁移段）**
   - 最强的理由：迁移只跑一次，运行时没有"兼容形状"的分支。
   - 为何被否：端点与附注状态在**安全存储**里（不是 sqflite 的 `meta` 表），
     没有现成的 data-migration 钩子；而旧数据归属哪台电脑只有读凭据的人知道。
     读时补前缀只需几行，且下一次写入自然收敛到新形状。

## Consequences

- 收益：同一局域网地址可以被两台电脑各自记录；切到 B 不再继承 A 的"成功过"与
  "记住的那条"；切回 A 时页签/草稿/落点都还在（`host.<hostId>.` 桶）。
- 收益：`repo.info` 第一次能告诉手机"这台电脑叫什么"，为切换界面准备了展示值；
  名字与身份（`pcSignPubHex`）的分工写死在注释里。
- 代价：端点的 id 变成不透明字符串（`hostId|url`），排序/调试时要记得它不再等于 url；
  `hidden` / `succeeded` 的落盘形状随之变化（读时迁移，旧新两种都认）。
- 代价：`remembered` 的落盘键名沿用旧名但值换成 id —— 只有"带不带 `://`"能区分两种形状，
  这条兼容分支要活到"确认没有旧安装"为止（下一次大版本）。
- 代价：`UiStateStore` 不再是"一段键"，`open()` 多了一次 `host.` 范围查与最多一次搬写；
  未配对时写的是旧平铺键，与桶并存一段时间（迁移后旧键消失）。
- 未覆盖：端点表"别的电脑报的自动条目直接剪掉"仍是现行规则（换回去靠重新自报）；
  "切走不删、只降序"是切换那一步（落地顺序第 4 步）的改动。
- 未覆盖：手机侧给电脑改名的 `host.<hostId>.name`、同名用公钥短码区分、切换界面 —— 都在后面的步骤。
