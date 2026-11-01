# Agent Note: 「没变就别再搬」怎么实现 —— 先归因，再给快照一个能自证的摘要

Status: implemented（2026-11-01）

## Problem

一次"回前台、什么都没变"的实测（`d61cf622`，直连 8790，profile `dsh-mobile-test`，
重复三次完全一致）：

```text
connector.bytes.outbound  +230 864 B      frames.inbound +183
```

而按"我们主动拉的快照"摊开只有 50 KB 量级。于是给 `connector.bytes.outbound` 加了
**纯观测**的两组拆分（`connector.bytes.out_frame.<帧类型>` / `connector.bytes.out_method.<方法>`
—— 方法名只有 `method-face` 知道，`res` 帧头不带它，所以记账点放在那里）。同一次回前台的拆解：

| 账本 | 字节 | 占比 | 是什么 |
|---|---|---|---|
| `out_frame.ev` | **104 683** | **45%** | 恢复订阅后的**会话事件重放** |
| `out_method.session.list` | 34 149 | 15% | 列表一页（50 行） |
| `out_method.workspace.list` | 9 749 | 4% | 工作区 / 归档 / 置顶全集 |
| `out_method.session.projections` | 6 798 | 3% | 当前会话投影（12 次 × ~570 B） |
| `out_method.session.modelCatalog` | 2 663 | 1% | 模型目录 |
| `out_method.repo.info` / `endpoint.describe` / `permission.catalog` / `settings.describe` / `agentPresets.list` / `job.list` / `sync.hello` | 4 794 | 2% | 其余快照 + 握手 |
| **未计量**（`status` / `job` / `host` / `presence` / `pong` / 握手帧） | **~69 600** | **30%** | 还没加计量 |

**结论（与我先前的猜测相反）：这不是"缓存没做"的问题。**
那 230 KB 里真正属于"快照扇出（landing）"的只有 **56.5 KB（24%）**，45% 是**重连时的
会话事件重放**，另外 30% 连计量都还没有。把缓存建在快照上顶多省 22%，
而"重放 104 KB"是一个恢复策略问题，缓存恰好治不到它。

## 三个账本，三种治法（不许互相替代）

| 账本 | 病 | 治法 | 归属 |
|---|---|---|---|
| **快照扇出** 56.5 KB | 每次重连 / landing 都重拉，而内容大多没变 | **摘要校验**（本文第 3 节） | 本仓可自决（连接器 + 手机） |
| **事件重放** 104.7 KB | 空闲重连也把订阅会话的事件重放一遍 | 恢复策略（见第 4 节，**待查**） | 通道语义（契约 §5.7 恢复） |
| **未计量 ~69.6 KB** | 不知道是谁 | 先把 `status` / `job` / `host` / `presence` / `pong` 也计入 `out_frame.*` | 纯观测，便宜 |

## Decision（只对第一本账给设计）

**给快照（`res` 应答）加"内容摘要"校验：客户端带上"我手里那一包的摘要"，连接器用
"它将发出的那份字节"算摘要，一样就回 `{notModified: true}`，不一样才发正文。**

### 形状

```ts
// 请求（所有快照方法统一，可选）
{ ..., digest?: string }          // base64url(sha256(box 明文))，≤43 字符
// 应答
{ notModified: true }             // 约 20 B，替代正文
// 或原来的正文（并可由手机从正文自行算摘要，不需要新增字段）
```

- **摘要算在服务端**：`method-face` 在 `resFrame()` 之后、发送之前对 `response.box` 求
  sha256（同一处的 `onResponse` 记账点已经知道方法名与字节数，挂在那里即可）。
- **手机侧存"上一次成功应用那一包的摘要"**，按 `(method, limit, offset)` 分别存 ——
  分页之后同一个方法在不同参数下是**不同的包**，共用一个摘要就是错配。
- 失配（内容变了）⇒ 照常发正文，手机照常应用并更新摘要。
- `notModified` 时手机**什么都不做**（既不清数据，也不报错，更不弹"没变化"）。

### 为什么它不是第二份真值（这是能否采用的关键）

1. 摘要由**将要发出的那份字节**算出 —— 与正文同源，不是另一条独立观察。
2. **答错的方向只可能是"多发一次"**：摘要不同就发正文；客户端摘要丢了/过期了也发正文。
   绝不会出现"服务端说没变、客户端却是旧值"——因为服务端每次都**重新算**。
3. 不需要宿主配合（我们不改 DSH），也不需要给每个 key 造 `rev`（那是被否过的第二真值，
   `2026-10-31-host-state-sync.md` 的 Open question 2）。
4. 与"何时重取"完全解耦：**失效仍由 `host` 帧决定**；摘要只回答"这一次搬不搬"。

### 边界与代价

- **仍是一次往返**（省的是字节，不是 RTT）。要连往返一起省，得推翻"快照方法唯一真值"，
  不在本方案内。
- 摘要只对**同一连接内一致的数据视图**有意义；跨连接也安全（比对在服务端），
  但跨重连必须**重新建立摘要**（客户端换连接后第一次请求不带 `digest`）。
- 服务端多一次 sha256：`session.list` 一页 ~34 KB，按微秒级算，相对 JSON 序列化是噪声。
- 新增的只有"可选字段"：老客户端不带 `digest` ⇒ 行为逐字不变。

### 预期收益（按实测推）

一次"什么都没变"的重连：快照 56.5 KB → 约 **0.7 KB**（12 个 ~60 B 的 `notModified`）。
总账 230.9 KB → **~175 KB**（省 24%）。**剩余大头仍是重放与未计量部分**。

## 第 4 节：事件重放那 104 KB（本文不设计，只列判据）

排除掉两个已知原因再谈设计：

1. **是不是本来就不该重连？** 计数显示这次回前台里 `connect.count +1`、`handshake +1`、
   `state.transitions +4` —— 也就是说**手机在后台被掐了 socket**，回前台是重连而不是续用。
   若半开/心跳判据能更早察觉、或后台保活更稳，这一整笔都不发生。
2. **重连之后为什么是重放而不是增量？** 契约的恢复语义是"从游标续传"，空闲期间没有新事件
   时**不该有字节**。104 KB 说明游标没被用上（`snapshotRequired`？缓冲空？订阅恢复把
   "最近窗口"整段回放？）。判据：同一条连接上 `session.subscribe {since: <有值>}` 的应答
   应当只有 `credit`，没有 `ev`。
3. 先修好 1 或 2 任一，再评估是否还需要"缓存"来治它 —— **用缓存治重放是拿错工具**。

## Alternatives considered

1. **跨重连保留快照（不验证）** —— 已被 `2026-11-01-refetch-scope-by-trigger.md`
   备选 4 否掉：断开期间收不到事件，留缓存等于"用旧值相信自己对"。**本方案不复活它**：
   我们保留的只是**摘要**，不是数据结论；结论永远来自服务端的这一次计算。
2. **给每个 key 造 `rev`** —— 被否（同上）：`session.projections` 没有版本号，
   拼出来的 rev 是第二真值，且漏收时会让客户端相信自己是最新的。
3. **让宿主提供 ETag / If-None-Match** —— 宿主没有这个接口，且我们是插件，改不了宿主。
4. **按行增量（`session.row`）** —— 归因显示"行"是 34 KB（15%），而摘要能把它压到 ~60 B；
   行级增量要换来的额外收益只有"内容真变了时少发 49 行"，却要引入行级合并语义。
   **继续搁置**，判据：摘要上线后若"内容变了"的那类重取仍是常态大头，再谈。
5. **什么都不做** —— 每次重连 230 KB、每次改标题 47 KB，按中转的按字节额度算不是小数。

## 落地（2026-11-01）

实施时按上面的形状做的，两处与设计稿不同，都在下面说清了代价：

1. **"未计量的 30%"归因是错的（实测推翻）**。补记账时顺手把三个账本对齐了一次：
   `Σ connector.bytes.out_frame.* === connector.bytes.outbound` 现在是**恒等式**
   （同一次 `emit` 记两笔，`tests/out-frame-bytes.test.ts` 直接断言差额为 0）。
   真机一次"什么都没变"的回前台（`d61cf622`，230 920 B）：

   | 帧类型 | 线上字节 | 占比 |
   |---|---|---|
   | `ev`（会话事件重放） | **147 037** | 63.7% |
   | `res`（快照扇出） | 76 638 | 33.2% |
   | `credit`（流控回执，183 帧 × ~37 B） | 6 859 | 3.0% |
   | `hello-ack`（握手） | 386 | 0.2% |

   也就是说：**规划稿里"status / job / host / presence / pong 约 69.6 KB"并不存在**
   （实测为 0），那 30% 几乎全是**封箱后的 base64 放大 + 帧头**（口径不同造成的）：
   快照 56 536 B 明文 → 76 638 B 线上，重放 104 683 B 明文 → 147 037 B 线上。
   推论：**省正文省的是线上字节，比例与明文一致**（摘要把 56.5 KB 明文压到 ~0.7 KB）。

2. **摘要做在信封层，白名单从 `HOST_STATE_KEYS` 派生**。请求带 `digest`（不在 `params` 里：
   它说的是"这一包字节我手里有没有"，与方法的业务参数无关）。白名单 = 那九个 key +
   `endpoint.describe`，唯一拼写处 `connector/src/protocol/snapshot-digest.ts`。
   手机侧不抄这份名单：给白名单外的方法带摘要是合法的，只是不比对（多发一次正文）。

3. **手机侧多了一张"待认领"表**。`callSnapshot` 拿到正文时先记 pending，应用成功才
   `commitSnapshot`。两张表而不是一张，理由就是"记早了 = 声称我手里有它"。

4. **一处口径改动**：`session.projections` 的目录三态在**带摘要的刷新**里不再先置
   `loading`。"没变"是常态，先闪一下"正在加载"再退回原样是纯噪声；
   首次读（手里没有那一包）仍然置 `loading`（`test/subagent_panel_test.dart` 同步改了断言）。

## Testing

- 连接器：同参数同内容两次请求 ⇒ 第二次 `notModified`（且 `bytes.outbound` 只涨 ~20 B）；
  内容改一个字段 ⇒ 第三次返回正文；**分页参数不同 ⇒ 摘要不互相命中**；
  不带 `digest` ⇒ 与今天逐字相同（老客户端）。
- 手机：`notModified` 不触发 `notifyListeners`（没有新数据）、不清空已有行、
  不落 `lastError`；**摘要跨重连继续带**（设计稿曾写"换连接后不带"，
  实施时按"服务端每次重算 ⇒ 答错只可能多发"取舍，留着更省）。
- 真机：同一条探针量"什么都没变的重连"，快照那 56.5 KB 应降到 ~1 KB 量级。

实际落地（数字都是实测 / 用例计数，不是估计）：

- connector：`tests/snapshot-digest.test.ts` 9 条 + `tests/out-frame-bytes.test.ts` 2 条
  + `tests/session-subscriptions.test.ts` 2 条；`pnpm test` **803 → 816**，`tsc` 干净。
- app：`test/snapshot_digest_test.dart` 3 条 + `test/sync_client_test.dart` 新增 2 条
  （**真实现 + 假传输**：第二次请求的 `digest` 真的等于上一包明文的 sha256；
  没 commit 时不带摘要）；`flutter test` **1634 → 1640**，
  `flutter analyze` / `dart analyze --fatal-infos` 干净，`verify-platform-boundary`
  **679 → 690**（新增 3 个 Dart 文件），`verify-rpc-single-caller` PASS。
- 跨端口径向量：`{"ok":true,"result":{"a":1}}` → `C-IwaBxQXATEjck-6Rpr16aLFxI7Ntsn94ThxOhHbV4`
  （两侧用例各钉一次；Dart 的 `base64Url.encode` 会补 `=`，必须去掉）。
