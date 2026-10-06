# Agent Note: 手机端连接层落地——把"错误码"从字符串换成枚举，因为报错类别决定下一步动作

Status: implemented（2026-10-02 落地：`app/lib/core/` 的连接层七个文件 + 四组新测试）

## Problem

### 一、`core/` 只到会话层，连接层还缺一整块

上一轮做完 `core/` 的会话层（frame / crypto / handshake / items / recovery / flow）后，
`SyncClient`（连接状态机 + 订阅管理）还只是一个**只有接口没有实现**的声明。
而没有它，`data/` 与 `ui/` 都无处接线：UI 需要一个"连接状态流"和一个"会话更新流"，
它们都由 `SyncClient` 拥有（`app-channel-client.md` §2 的"一个 owner"）。

### 二、错误码是**字符串**时，拼错会静默降级

电脑侧（`connector/src/protocol/errors.ts`）的 `ProtocolError` 构造函数收 `string` 再归一：
不在封闭表里的码一律降级成 `internal`。那条归一化是**为对端给的码**设计的
（"不能因为对端发了个新码就走 default 分支"），但同一套逻辑用在**我们自己构造**的码上时，
`'protocol/bad-fram'`（少个 e）会**静默变成 `internal`**：编译通过、测试可能也过，
只是错误类别变了。

而错误类别决定下一步动作 —— 本轮之前刚踩过一次同类事故：
`not-paired` 被报成 `bad-frame`（见 `2026-10-02-mobile-core-crypto-choice.md` 的附带修复）。
两者的客户端动作是"清除凭据回配对页"与"重试"，**报错类别错了用户就永远卡在重试上**。

## Decision

**连接层落地；同时把"我们自己构造的错误码"从字符串换成枚举，只给"对端给的码"保留归一化。**

准入门槛（可机械判定）：

1. **错误码是枚举**：`ErrorCode.badFrame` 拼错是**编译错误**；
   对端给的线上字符串走 `ErrorCode.fromWire`（未知归 `internal`，封闭表的纪律不变）。
2. **状态机是白名单**：非法迁移抛错（`connection_test.dart` 有专门用例）。
3. **连接层每个判据都有测试**：状态机 / 退避 / 心跳半开 / 箱的方向与重放 /
   握手两道校验 / 写操作幂等 —— 四组新测试共 **56 项**。
4. **`SyncClient` 能被假传输驱动**：`ChannelTransport` 是注入的缝，
   于是"断连 / 退避 / 半开 / 握手失败"在毫秒内可测，不需要真机也不需要真网络。

### 关键取舍一：错误码用枚举，但保留"对端给的码"的归一化

这不是"枚举比字符串好"的泛泛之谈，而是**两个方向的错误各需要一个不同的处理**：

| 来源 | 处理 | 理由 |
|---|---|---|
| 我们自己构造 | 枚举（拼错即编译错误） | 拼错一个码会静默改变客户端动作 |
| 对端给的线上码 | `fromWire`（未知归 `internal`） | 不能因为对端升级了就逼我们走 `default` |

迁移时用了一个**带命中数断言的一次性脚本**（`app/tools/migrate-error-codes.mjs`）：
27 处替换，每处都断言"预期命中数"，对不上就**一个文件都不写**。
第一次跑时它正确地拦住了我数错的期望值（`Select-String` 每行只报第一个匹配，
我据此写下的计数偏小），第二次跑时它又拦住了"正则没吞掉原逗号"留下的 `,,` 残渣
（数量是对的，所以数量守卫拦不住它 —— 于是补了一条"改完不许出现 `,,`"的兜底断言）。

### 关键取舍二：`SyncClient` 的诊断面单独一个接口

`pairingFrames` / `jobFrames` / `presenceFrames` / `lastProtocolError` 这些是测试与日志要看的，
但**不该在 `SyncClient` 上**：UI 看到"收到的帧列表"会诱使界面层自己解析帧，
而那正是分层要防的（UI 只该消费 model）。所以拆成 `SyncClientProbe`，
测试按需转型 —— 类型系统因此替我们守住了"UI 不认识帧"。

### 关键取舍三：`LineSplitter` 归编解码层，传输层只给原始片

最初我把 `TransportMessage` 定义成"一个完整行"，同时又在 `SyncClient` 里留了
`LineSplitter` —— 结果是那个字段**根本没被用到**（`unused_field` 警告抓到了它）。
两种写法都"能跑"，但含义完全不同：如果传输层负责切行，`\n` 的规则就有**两个 owner**，
而其中一个（真实 WSS 实现）将来会在另一端被写出来。

改法：`TransportMessage` 交出**原始片**（`chunk`），拼行留在 `SyncClient` 里调 `LineSplitter`。
分隔符规则因此只有一个 owner —— 这条纪律本项目踩过一次（漏 `\n` 的表现是
"两侧都正常、对端什么都没收到"）。

### 关键取舍四：定时器注入，且**续期前要检查自己还该不该活着**

`_startTicking` 的 `run()` 最初无条件在末尾重排下一次 tick。而半开路径会调
`_enterClosed()`（它取消了 tick 并可能已进退避），于是那个已经"该死了"的定时器
继续跑，在 `_connect()` 的 `await` 中途又调一次 `_enterClosed()`，
把状态从 `connecting` 推到 `closed` —— 于是 `await` 回来后的 `to(handshake)`
变成**非法迁移**（实测报错：`backoff → handshake`）。

这是**测试抓到的**（不是推理出来的）：心跳那组用例推进 4 个心跳周期后，
状态机抛了 `IllegalTransitionError`。修法是续期前判断 `_closed || _cancelTick == null`。

## Alternatives considered

1. **保持字符串错误码（照抄电脑侧）**
   - 最强的理由：与电脑侧逐字对称，迁移成本为零，而且归一化逻辑已经在那边验证过。
   - 为何被否：电脑侧那套归一化是为**对端给的码**设计的，而我们**自己构造**码时
     需要的是"拼错要吵"。两者用同一个函数，等于把"编译期能抓的错"推迟到运行期，
     而这一层的错误类别直接决定用户下一步动作（回配对页 / 重试）。
2. **把错误码做成 `enum` 但保留字符串构造（两套并存）**
   - 最强的理由：迁移不用改 27 处调用点，渐进式。
   - 为何被否：两套并存等于**两个来源**，而"哪个码该用哪种构造"没有机械判据 ——
     迟早有人图省事写字符串，于是枚举的价值（编译期检查）被绕过。
     一次性迁移 + 命中数断言的成本可控（一次跑绿），比长期养两套便宜。
3. **`SyncClient` 只给 UI 一个"连接状态 + 会话更新"的最小面，诊断面完全不给**
   - 最强的理由：最干净，UI 绝对看不到帧。
   - 为何被否：测试需要观察"收到的配对帧 / 任务帧 / presence"，
     否则那些路径只能靠端到端场景间接覆盖（而它们恰恰是"帧收到了但没交给对的人"这类 bug）。
     单独接口是"给测试用"与"不给 UI 用"之间的正确切法。
4. **传输层负责切行（`TransportMessage` = 一行）**
   - 最强的理由：调用方更省事，`SyncClient` 不用管分帧。
   - 为何被否：`\n` 的规则就有了两个 owner（真实实现与测试替身），
     而这条规则**只有一个正确答案**，且踩过一次静默故障（漏 `\n` → 对端永远收不到）。
     规则该住在编解码层，与 `encodeFrame` 挨着。
5. **`data/` + `model/` 先做，连接层推后**
   - 最强的理由：DTO 与 store 接口更"看得见"，而连接层抽象、不好演示。
   - 为何被否：`data/` 的 store 需要"什么时候落盘、什么时候发 `persisted`"这个驱动，
     而那个驱动在连接层（`_sendPersisted` 在 `commit` 之后才发）。
     先做 data 会得到一堆没有调用者的接口。

## Consequences

- 收益：`core/` 的连接层完整（状态机 / 退避 / 心跳半开 / 箱 / 握手驱动 / outbox / SyncClient），
  且**全部可用假传输驱动** —— 最难在真机上复现的四类场景（断连、退避、半开、握手失败）
  现在都是毫秒级的单测。测试从 71 项涨到 **128 项**。
- 收益：错误码改成枚举后，"拼错一个码"从静默降级变成编译错误；
  而对端给的未知码仍然安全（`fromWire` → `internal`）。
- 代价：`ErrorCode` 与电脑侧的 `ERROR_TABLE` 现在是**两份**（一边 TS 字符串、一边 Dart 枚举）。
  它们必须逐字对齐，而目前**没有门禁**盯着这件事 —— 新增一个错误码要两边都改。
  （缓解：两边的 `wire` 值就是契约 §3.1 的拼写，而契约是唯一真值源。）
- 代价：`SyncClient` 的实现有 900 余行。它承载了帧分派、握手装配、流控记账、
  订阅管理、重连与退避六件事 —— 已经接近"该拆"的边界。下一轮若继续长，
  应把**帧分派**与**订阅管理**各拆出去（它们与"连接生命周期"是三条独立的时间线）。
- **仍未做**：`data/`（DTO 与 sqflite store）、`model/`、`ui/` 逐屏、三端能力包、
  `platform/` 的真实 `ChannelTransport`（用 `dart:io` 的 `WebSocket`）。
  **真机仍在整条链末端**。
- **本轮发现但未修**（与本轮无关的既有问题）：无。

## 落地时改动的文件

| 文件 | 做了什么 |
|---|---|
| `app/lib/core/errors.dart` | **新增**：封闭错误码表（枚举）+ `ClientAction` + `ProtocolException` |
| `app/lib/core/connection.dart` | **新增**：状态机（白名单迁移）+ 退避（注入随机） |
| `app/lib/core/keepalive.dart` | **新增**：心跳与半开判定（时间由调用方传入） |
| `app/lib/core/transport.dart` | **新增**：传输缝（`ChannelTransport`，交出**原始片**） |
| `app/lib/core/box.dart` | **新增**：AEAD 封箱/解箱（方向由角色定、nonce 绊线、先验后进） |
| `app/lib/core/handshake_driver.dart` | **新增**：发起方握手（**建好就发 hello**、两道校验） |
| `app/lib/core/outbox.dart` | **新增**：写操作队列（先落盘再发、FIFO、落盘失败即拒） |
| `app/lib/core/sync_client.dart` | **新增**：`SyncClient` 接口 + `SyncClientProbe` 诊断面 + deps |
| `app/lib/core/sync_client_impl.dart` | **新增**：接线实现（帧分派、流控记账、重连、订阅） |
| `app/lib/core/{frame,crypto,handshake,flow}.dart` | **改**：错误码从字符串换成枚举（27 处） |
| `app/test/connection_test.dart` | **新增** 16 项：状态机 / 退避 / 心跳半开 |
| `app/test/box_handshake_test.dart` | **新增** 15 项：箱的方向、篡改、重放、握手两道校验 |
| `app/test/sync_client_test.dart` | **新增** 26 项：接线 e2e（假传输）、写操作幂等、LiveAccumulator |
| `app/tools/migrate-error-codes.mjs` | **新增**：一次性迁移脚本（带命中数断言，已用完） |
| `app/tools/migrate-test-error-codes.mjs` | **新增**：同上（测试侧那一半） |

证据：`flutter test` **128 项全绿**；`dart analyze --fatal-infos` 0 问题；
`dart format --set-exit-if-changed` 0 文件需重排；`verify-platform-boundary.mjs` **67 项**全绿
（`core/` 仍是纯 Dart —— 传输缝是注入的）；`protocol` 486 / 26 / 49 全绿。

**四处变异校验**：① 箱的守卫提到解箱之前 → 2 项红（「先验后进」与「伪造的 fc」）；
② 状态机去掉白名单 → 1 项红（非法迁移那条）；③ `flush` 改成"跳过发不出去的" →
2 项红（FIFO 顺序那条）；④ （上一轮的）`not-paired` 翻译 → 2 项红。
