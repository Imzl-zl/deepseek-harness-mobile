# 手机端通道客户端:落地设计

契约见 `remote-channel.md`;多端边界规则见 `app-platform-boundaries.md`(本文件不重复 C1–C6 判据,只写通道客户端怎么落)。

---

## 1. 分层与依赖方向

```text
app/lib/
├── core/                        纯 Dart,零平台依赖(verify-platform-boundary 会拦)
│   ├── frame.dart               帧编解码 + AAD 规范化(契约 §3)
│   ├── errors.dart              封闭错误表与客户端动作(契约 §3.1)
│   ├── crypto.dart              握手、HKDF、AEAD、fc 计数器(契约 §4)
│   ├── handshake.dart           三帧握手的字段与 transcript 拼串(契约 §4.1)
│   ├── handshake_driver.dart    发起方握手驱动(手机恒为发起方)
│   ├── box.dart                 箱容器编解码(角色定向、nonce 绊线)
│   ├── connection.dart          连接状态机与退避(契约 §2.2)
│   ├── keepalive.dart           心跳与半开判定(60 s / 2 周期)
│   ├── flow.dart                流控窗口与 credit 回执(契约 §4.3)
│   ├── recovery.dart            恢复判定、快照分页与拼接(契约 §5.4)
│   ├── items.dart               itemId 推导与 upsert(契约 §5.2)
│   ├── outbox.dart              写操作待发队列(幂等键驱动)
│   ├── transport.dart           ChannelTransport 接口(交出**原始片**,分帧归 frame.dart)
│   └── sync_client.dart         连接状态机 + 订阅管理(接口与 SessionDelta)
│       sync_client_impl.dart    上述接口的实现
│       connection_resources.dart 每连接资源束(建/废各一处)
│       call_registry.dart       在途请求表(断连即整体拒绝)
├── data/
│   ├── projection.dart          事件 → 界面条目的**唯一**投影(唯一认识事件语义处)
│   ├── session_store.dart       条目表(upsert-only、按 seq 排序、通知合并)
│   ├── app_model.dart           应用级状态(ChangeNotifier),UI 的唯一数据入口
│   ├── store.dart               ← 接口(sqflite 实现在 platform/)【未落地】
│   ├── secure_store.dart        ← 接口(三端实现见 §5)【未落地】
│   └── push_registry.dart       ← 接口(推送令牌登记)【未落地】
├── model/                       领域模型(ChatItem sealed:消息/工具/审批/其它)
├── ui/                          逐屏(消费 model,不认识帧)
│   ├── session_list_page.dart   会话列表(空态与失败态分开)
│   └── chat_page.dart           对话页(气泡/工具行/审批行/输入栏)
└── platform/                    唯一装配点:选择各能力实现
    └── websocket_transport.dart 真实 WSS(`IOWebSocketChannel`,令牌走升级头)
```

**`data/projection.dart` 是事件语义的唯一归宿**:`core/` 只推导 `itemId`
(契约 §5.2)并把原始 `type`/`data` 原样带上,由这一处决定"渲染成什么"。
UI 一旦开始认事件类型,同一件事就会在两个地方各写一遍。

规则(由 `node app/tools/verify-platform-boundary.mjs` 强制):

- `core/` 与 `data/*.dart`(接口)不得出现 `dart:io`、`package:flutter/*`、`Platform.`、`MethodChannel`。
- `ui/` 不得 import `packages/*_ios|_android|_ohos`。
- `core/` 的所有 IO 走注入接口 ⇒ **纯 Dart 单测里可以直接跑 `protocol/fixtures`**。

---

## 2. 关键类型(签名级)

**出帧一律以 `\n` 结尾**(§3 的行级分帧):分帧器只在读到换行时交出一帧,漏掉它的表现是「两侧都正常、对端什么都没收到」。Dart 侧因此在唯一的出帧口(`encodeFrame`)补换行,别让调用点各自记得。

```dart
// core/sync_client.dart —— 连接与订阅的唯一 owner
abstract class SyncClient {
  Stream<ConnectionState> get connection;      // idle/connecting/handshaking/serving/backoff
  Stream<SessionDelta> sessionUpdates(String sid);
  Future<void> subscribe(String sid, {required int since});
  Future<void> unsubscribe(String sid);
  Future<T> call<T>(String method, Map<String, Object?> params, {String? requestId});
  Future<void> setAppState(AppState state);    // foreground/background:决定 claim 与重连
}

// core/recovery.dart —— 恢复判定与快照拼接,纯函数 + 显式输入
sealed class RecoveryOutcome {}
class ApplyDelta extends RecoveryOutcome { final int from, to; final List<Item> items; }
class NeedSnapshot extends RecoveryOutcome { final SnapshotReason reason; }
class SnapshotPage extends RecoveryOutcome { final int asOfSeq; final bool hasMore; final String? cursor; }

RecoveryOutcome decideRecovery({required int since, required int? latest, required WindowState window});

// core/items.dart —— itemId 推导(契约 §5.2 的表格)
String itemIdOf(SessionEvent e);

// core/outbox.dart —— 写操作:先入队落盘,再发送;幂等键保证重发安全
abstract class Outbox {
  Future<void> enqueue(String method, Map<String, Object?> params, {required String requestId});
  Future<void> flush();     // 连接可用时按序发送
}
```

设计要点:

- **一个 owner**:连接、订阅、恢复、流控全部由 `SyncClient` 持有,UI 只订阅它暴露的流;不存在第二处重连逻辑。
- **恢复是纯函数**:`decideRecovery` 的输入只有 `since` / `latest` / 窗口状态 ⇒ fixtures 可以直接调它(snapshot 分页的状态机在 `recovery.dart` 内)。
- **写操作先落盘**:入 `outbox` 并落盘后才发送;`requestId` 在入队时生成,重发复用同一个 ⇒ 幂等(I8)。

### 2.1 订阅与渲染状态

| 状态 | 触发 | 行为 |
|---|---|---|
| `cold` | 未订阅 | 只显示本地缓存,顶部显示"未连接/未同步" |
| `recovering` | 收到恢复应答 | 增量:直接 upsert;快照:进分页拼接,期间 `ev` 只缓存不渲染 |
| `live` | 水位已对齐 | 渲染 `ev` / `live` / `job`;`ev` 落盘后才发 `persisted` |
| `stale` | 出现空洞 / 收到 `snapshotRequired` | 立即回 `recovering`,UI 保持旧内容不闪空 |
| `offline` | 连接断 | 停止发 `persisted`;`outbox` 挂起;展示离线态 |

**UI 永不闪空**:`stale` → `recovering` 期间保留旧 items(与 DSH 桌面的做法一致),只在分页完成后整体替换。

### 2.2 流式渲染(`live` 帧)

- **先按帧类型分派**:assistant 流走 `live`,任务输出走 `job`(契约 §3 的术语表说明了两者为什么**不能**共用一个帧类型:任务输出的"修订号"是字节偏移,会跳号,而这里的累加器把跳号读成"丢流")。
- 每会话一个 `LiveAccumulator`:`{stream, rev, text}`。收到 `live`:
  - `stream` 变大 ⇒ 换流(上一次尝试结束),重置累加器;
  - `rev == last + 1` ⇒ 追加;`rev` 跳跃 ⇒ **丢弃该流已累积内容并停止渲染**,等持久 `assistant/message` 到达(自愈,不请求重传);
- UI 侧节流到 **每 16 ms 一帧**(把 50–100 ms 的批量再合并成屏幕帧);文本用 `Text.rich` + 段级缓存,不重建整棵子树。
- 持久事件到达时**替换**累加器内容(以持久为准,避免"流式与最终文本不一致")。
- **任务输出(`job` 帧)不走累加器**:按 `jobId` 各自维护一个尾部缓冲(客户端尾 128 KiB),`kind: 'output'` 追加、`kind: 'status'` 收口;**`gapBefore` 与流错误必须显式渲染**(不做静默拼接,见 `../plugin-and-jobs-notes.md` §B.4)。
- **流式文本**独立成一条订阅,不走 `AppModel` 的通知路径:累加器的当前内容是
  `ValueListenable<String?>`(`AppModel.liveTail`),**只有尾条目**听它;
  纯流式的 delta(`events` 为空、只有 `liveText`)**不 `notifyListeners()`**。
  尾条目的**存在性**(列表多不多一格)仍在流开始 / 结束时通知一次 —— 那不是"流式期间"。
  判据:流式输出期间会话列表 widget 的重建次数 = 0(`app/test/live_tail_test.dart` 的计数桩)。

### 2.3 宿主状态变更(`host` 帧)与快照登记表

电脑侧改了模型 / 权限档 / 设置 / 标题 / 任务表 / 模型目录 / 权限预设目录时,会来一条
`host` 帧(契约 §5.9):**只是"可能过期了"的提示,不带数据**。客户端收到后按 key 重取对应快照。

- **key 是方法名**(契约 §5.9 的封闭集,九项):`session.list` / `session.projections` /
  `settings.describe` / `job.list` / `session.modelCatalog` / `permission.catalog` /
  `agentPresets.list` / `workspace.list` / `repo.info`。会话级只有 `session.projections`
  与 `job.list`(必须带 `sid`),其余宿主级(帧头 `sid` 忽略)。
- **同 key 100–300ms 内合并成一次**(`data/host_state.dart` 的 `HostStateRefresher`,
  默认 150ms,启动点注入)。**按 key 分桶**:不同 key 各算各的,不做全局节流 ——
  一次"切模型"会同时发 `session.list` 与 `session.projections`,它们不该互相等。
- **在飞期间再来同 key**:记一笔,等那次收尾再补一次(与 `_refreshProjectionsOnce` 同形)。
  直接并发两次会让**两个应答乱序落地**(投影包没有版本号可比,后到的旧包会盖掉新包)。
- **断连期间不排队**:连接断掉时清空所有待发桶 —— 重连由 `landAfterConnect()` 兜底
  (它把整份快照重取一遍)。排队只会让重连瞬间打出一串必然过期的请求。
- **未知 key 忽略并计数**(`AppModel.unknownHostStateKeys`):将来连接器多一个 key 时,
  症状必须是"计数器涨了",而不是"通知到了但什么都没发生"。

**登记表**(唯一拼写处 `app/lib/data/host_state.dart`,一条 `key → 重取函数 → 允许的触发点`)。
它就是"拉什么、何时拉"的**唯一清单** —— 产品路径上没有"把全套再拉一次"的入口:

| key | 重取 | 触发点 |
|---|---|---|
| `session.list` | `AppModel.refreshSessionRows()` | `notification` / `connectLanding` / `appResume` / `ownWrite` |
| `session.projections` | `AppModel.refreshProjections(sid)` | `notification` / `openSession` / `connectLanding` / `appResume` / `viewFocus` |
| `settings.describe` | `AppModel.refreshSettings()` | `notification` / `connectLanding` |
| `job.list` | `AppModel.refreshJobs(sid)` | `notification` / `openSession` / `connectLanding` |
| `session.modelCatalog` | `AppModel.refreshModelCatalog()` | `notification` / `connectLanding` |
| `permission.catalog` | `AppModel.refreshPermissionCatalog()` | `notification` / `connectLanding` |
| `agentPresets.list` | `AppModel.refreshAgentPresets()` | `connectLanding` |
| `workspace.list` | `AppModel.refreshWorkspaces()` | `connectLanding` |
| `repo.info` | `AppModel.refreshRepoInfo()` | `connectLanding` |

五列的判据:

- **`notification`** 只有六个 key 有:它们都有生产者(契约 §5.9 的触发点表),而
  "桌面改了、手机没动静"正是这条通道要消灭的那一类。`session.modelCatalog` 由四条宿主
  失效事件触发(`llm/adapters-updated`、`settings/document-updated`、`credentials/*-updated`),
  `permission.catalog` 由 `permission-presets/catalog-changed` 触发;
  `agentPresets.list` / `workspace.list` / `repo.info` **不在内** —— 宿主没有
  "这张表变了"的事件,编一个就是替宿主做决定。
- **`connectLanding`** 是**全部九项**:通知只在服务态到达,断开期间在电脑上改的一切
  (反了密钥、加了模型、换了预设表、改了工作区)手机**一条事件都收不到**,重连把每份
  快照重取一遍是唯一的兜底。目录**不跨重连缓存**也是这一条的反面 ——
  本批之后这九项仍然**每次都问**,只是问的时候带上 `digest`:没变的那些换回一个
  `{notModified:true}`(约 20 B),而不是整包正文。**"何时重取"没有因此改变**(仍归
  `host` 帧与这一列),变的只是"这一次搬不搬"。
- **`appResume`** 只有行 + 当前会话的投影:回前台的语义是"对齐这一屏",而设置 / 目录
  要么有通知(`settings.describe`)、要么极低频(四个目录),每次回前台都拉一遍不值。
- **`openSession`** 只有会话级两个:切过去那一刻任务表与投影都可能是旧的。
- **`viewFocus`** 只有 `session.projections`(由轨迹页签发起,`AppModel.focusView(sid)`):
  那一屏的全部内容都在这一包里,而前四个时机**都不覆盖"会话没换、一轮还在跑"** ——
  一轮跑二十分钟时 `turn/end` 一次都不来,旧包就一直旧着(2026-11-04 真机:轨迹页空态,
  重启 App 才恢复)。进入这一屏就问一次,没变只花一个 `{notModified:true}`(约 41 B)。
  空态里的「重读」走同一个入口 —— 触发点仍只有登记表一处。
- **`ownWrite`** 只有 `session.list`:自己发起的写(切模型 / 分支 / 会话页"重试")
  由回执带回值,只需要**重拉行**校验身份字段;不压 150 ms 窗口(不是高频事件),
  也不拉目录(那些与这次写无关)。**不用回执改本地行**:行是电脑侧的身份字段
  (模型 / 标题 / `updatedAt` / 计数),本地改写就是第二个真值。

**首屏 = 一次并行批次,而不是一串 await**(`landAfterConnect`):

- 九项**同时发起**;`await` 的只有 `session.list` 那一行(落点读行里的 `updatedAt` /
  `running`),落点(`landOnSession`)紧跟着跑,其余八项在飞;
- 经中转时首屏因此从"六件串行"压到"一轮",而不是"先落点、目录后补" ——
  后者会让 blank 会话的 hero 先显示"拿不到模型"(`blank-session-hero.md`);
- **八项里任何一项失败都不拦住落点**:每个重取自己 `catch` 并落进 `lastError`,
  批次本身不抛(用例钉:目录抛错时 `landAfterConnect` 仍会 `landOnSession`);
- **一批只通知一次**:批内所有 `notifyListeners` 被闸住,批次收尾补发一次 ——
  否则四个目录各自的 `onChange` 加上行 / 投影 / 设置 / 任务表 / 工作区会让首屏整棵树
  重建**六次以上**（计数桩实测 8 次）。
  闸只在批次窗口内生效,批次外的通知照旧即时。

`refreshHostCatalogs()` 是"四个目录(模型 / 权限 / 预设 / `repo.info`)"这一件事的名字,
它内部同样把四份到达合并成一次通知。

机械保证(`app/test/host_state_test.dart`):两端 key 清单逐字相等、每个 key 至少一个
触发点、`notification` 可用的 key 恰好是上表那六个、每条 `fetch` 真的调到它名字指向的
那个方法(记账替身断言线上方法名)、一条 `{keys:['session.list']}` 通知**恰好一次**
`client.call`。

**四层分工(谁也不能替谁)**——把"要不要拉"拆成四个独立的问题,
分别由四件事回答,拿其中一个去替另一个就会出错:

| 层 | 回答的问题 | 判据/机制 | 替它会错在哪 |
|---|---|---|---|
| **快照** | 谁说了算 | 值一律取自快照方法(`session.list` / `session.projections` / 各目录),不推数据 | 推数据 = 第二份真值;`host` 帧只带 key 就是这个原因(§5.9) |
| **事件** | 什么时候可能变了 | 宿主事件 → `host` 帧;`notice` 只提示,不带值 | 用轮询替代 = 把判据从"变了"降成"到点了" |
| **分页** | 一次搬多少 | `session.list` 的 `{limit, offset}` + `hasMore`;一页 50 行 | 整表搬 = 每次变更都付全量(实测改一次标题 250 KB → 45 KB) |
| **缓存** | 这一次要不要搬 | **只在"能自证没变"时成立**:快照的 `digest` / 事件流的 `seq` 水位 | 不验证就留 = 旧数据被当成真值(断连期间收不到事件) |

**缓存在本仓的三档判据**(按"能否自证"分,不按"变化频率"分):

1. **能自证** ⇒ 可以省掉正文:客户端带上"我手里那一包的摘要/水位",由**产生数据的那一端**
   比对,一样就回 `{notModified: true}` / 不产生任何字节。**两处都在这一档**:
   - **事件流**:`seq` 水位 + 落盘 + `persisted`(所以重连只补"之后那一段");
   - **十个只读快照**:请求带可选 `digest`(契约 §5.7.1),摘要的键是 **`(方法, 参数)`**
     —— 分页后同一方法不同 `limit` / `offset` 是**两个包**,共用一个摘要就是错配;
     摘要**只在成功应用之后才记**(记早了等于声称"我手里有它",而解码失败时界面并没有
     那份内容),`notModified` 时**什么都不做**(不清数据 / 不报错 / 不通知)。
     跨重连继续带是安全的:服务端每次都重算,答错只可能多发一次。
2. **不能自证、但服务态期间事件完备** ⇒ 靠 `notification` 失效;**不跨重连保留**
   (断开期间收不到事件,留缓存等于用旧值相信自己对 —— 见 §5.9 规则 5 与前文
   `connectLanding` 那一列)。
3. **完全不能自证** ⇒ 每次拉(今天没有这样的快照了;给某个 key 造"版本号"来省字节
   仍是**第二份真值**,那件事被否过 —— 要走的是进白名单带摘要,不是造 rev)。

于是"凡是拉过一次就永久不拉"与"每次全量"都不对:**分页决定一次搬多少,缓存决定这次要不要搬,
事件决定何时可能变了,快照决定谁说了算**。四层里任何一层被另一层替代,症状都是安静的
(数据旧了不报错 / 带宽涨了没人看)。

---

## 3. 本地存储(sqflite)

表结构见契约 §8.3。实现纪律:

- **批量事务**:`ev` 每 64 条或 200 ms 提交一次事务;`persisted` 只在事务提交成功后发送 ⇒ 水位永不超过落盘内容(崩溃后最多重放一个批次,upsert 幂等)。
- **敏感字段加密**:payload 内的正文按字段级加密(密钥来自安全存储的派生密钥);数据库依赖系统级文件加密。
- **淘汰**:已归档会话的 items 保留最近 N 条(默认 500)+ 墓碑;超出按 `updated_at` 淘汰,重新订阅时走快照。
- **迁移**:`meta.schema` 同电脑侧规则,逐代迁移。

---

## 4. 渲染性能(Flutter 侧已知坑与对策)

| 风险 | 对策 |
|---|---|
| 长会话列表排版卡顿(`dart:ui` 排版只能在主 isolate,见 flutter#30604) | 按块懒加载:已完成消息冻结为不可变 widget 并缓存;只对可见块做 layout |
| 流式更新触发整段重排 | 累加器 16 ms 节流 + 段级缓存;不用 `SelectableText` 包整段(开销大) |
| 大对象(base64 图片、diff)阻塞 UI | >1 MiB 走 `refetch`;JSON 解码放 `compute`;图片走 `Image.memory` + 缓存,不逐帧解码 |
| 代码高亮开销 | 构建时按块算：`highlightCode` 在 `_DshCodeBlock.build` 里跑，`Highlight` 引擎只建一次（`dsh_code_highlight.dart` 的 `_engine`），token 结果**不缓存**。已知差异：DSH 只在代码块首次进入视口时高亮一次并缓存（`packages/client/ui-primitives/src/markdown/highlight.ts:286`、`useViewportHighlighting.ts:17,48`），手机侧同一块每次重建都会重算 |
| 长 Markdown | **不做段落切分**:查过 DSH,它也没有正文虚拟化/按段切,只在**流式期间冻结除末尾两块以外的块**(`packages/client/ui-primitives/src/markdown/incremental.ts:9-14,38` 的 `UNSTABLE_TAIL_BLOCKS = 2`)⇒ 手机侧照同一条做"流式只重排末尾" |

---

## 4.1 会话页渲染：与 DSH 的逐项对齐（2026-10-20）

规格一律取 DSH 源码行号；**每一处偏离都写明理由**。判定用的断言在
`app/test/render_alignment_test.dart` 与 `app/test/markdown_coverage_test.dart`。

| 面 | 值 | 规格出处 |
|---|---|---|
| 消息正文（Markdown base） | 14 / 24 | `packages/client/ui-theme/src/styles/gradient-shadow-text.css:93`（`--dsh-content-font-size`，默认 14 见 `ui-theme/src/theme-settings.ts:58`）、`ui-chat/src/client/chat/AssistantMarkdown.module.css:1-14` |
| 思考正文（compact） | 13 / 20、`label-tertiary`、段距 4 | `ui-primitives/src/markdown/MarkdownText.module.css:331-347` + `ui-chat/src/client/chat/ReasoningContent.tsx:16` |
| 标题字号 | h1 21/30·700、h2 19/28·700、h3 18/26·700、h4 14/24·600 | `gradient-shadow-text.css:65-110` |
| 工具卡展开正文 | 11 / 16 等宽、`label-secondary`、上限 150 + 内滚 | `ui-tool/src/client/tool/components/ToolRow.module.css:181-201`、`gradient-shadow-text.css:178` |
| 系统提示词 / 上下文注入正文 | 11 / 16 等宽、上限 141 + 内滚、左缩进 22、`markdown-code-block` 底 | `ui-chat/src/client/chat/ContextInjectionRow.module.css:50-64`（141 是 Figma 10:2482） |
| 折叠行 | 行高 24、标题 13/24、`label-tertiary`、图标 14 | `ui-primitives/src/DisclosureRow.module.css:36,50-72,100-105` |
| 斜杠命令 | disclosure 行 + 展开区 `11/16` 等宽、上限 260、`label-primary`；摘要展开后仍在 | `ui-chat/src/client/chat/GenericCommandCard.module.css:38-49`、`GenericCommandCard.tsx:40,67` |
| 节点图标 | 系统提示词 `browse`、上下文注入 `contextInjection` | `ui-chat/src/client/chat/SystemPromptRow.tsx:30`、`ContextInjectionRow.tsx:55` |
| 表格 | 自然宽度 + 横向滚动；单元格 `10px 16px`；只有行分隔线；`th` 左对齐 | `ui-primitives/src/markdown/MarkdownText.module.css:192-196,226-262` |
| 用户消息正文 | **纯文本，不跑 Markdown** | `ui-primitives/src/user-text.tsx:18-20`（`UserTextRun`：without Markdown or reference recognition） |
| 上下文注入 | `user/message` 里 **`source.kind !== 'user'` 的一律是上下文**（标题「上下文注入」+ 生产者），不是用户气泡 | `ui-chat/src/client/conversation-nodes/message.ts:79`、`ui-chat/src/client/locale.ts:126`、`ContextInjectionRow.tsx:57` |
| 原始 HTML | DSH 把标签当**字面文本**显示 | `ui-primitives/src/markdown/render.tsx:333-335` |
| 代码块头部 | 左 `[语言名 / 「代码块」]` + 右 `[自动换行][复制]`，按钮 28×28，banner 内边距 9/14/10/9 | `ui-primitives/src/markdown/CodeBlock.tsx:118`（正文 trim）、`CodeToolbar.tsx:44,51`（`supportsHighlighting(lang) ? lang : codeLabel`）、`CodeBlock.module.css:40-46` |
| 代码块默认换行 | 默认自动换行；点一次切横滚（`SingleChildScrollView` 横向），按钮图标在 `nowrapFill`/`wrapFill` 之间换 | `CodeBlock.tsx:157` 的 `useState(true)` |
| 复制反馈 | 复制成功后 1 秒内变对勾，文案 `复制` → `复制成功` | `CodeBlock.tsx:165-169`、`ui-chat/src/client/locale/zh.ts:6,8-9` |

实现侧的三个关键落点：

- **宽表为什么能横滚**：`flutter_markdown_plus` 只在 `tableColumnWidth` 是
  `IntrinsicColumnWidth` / `FixedColumnWidth` 时才套横向 `SingleChildScrollView`
  （`flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463`），默认 `FlexColumnWidth`
  （`style_sheet.dart:143`）没有横滚出路 ⇒ 我们固定用 `IntrinsicColumnWidth`。
- **围栏识别**：`~~~` 与 ```` ``` ```` 等价（`markdown-7.3.1/lib/src/block_syntaxes/
  fenced_code_block_syntax.dart:13`），行内 HTML 归一必须按"同记号、长度不短于开围栏、
  未闭合一直算围栏内"逐行扫描，否则会改写围栏内的源码。
- **流式形态**：DSH 的流式 arm 也把未闭合围栏渲染成代码块并逐块冻结
  （`ui-primitives/src/markdown/incremental.ts:10-14`），所以"途中显示成代码块"不是缺陷；
  要保的是**围栏闭合那一帧形态不变**。手机侧的流式尾条目与持久条目共用
  `AssistantHead` + `DshMarkdown`，避免流结束换条目时跳一下。
- **上下文注入不是用户消息**：DSH 把运行时上下文 / 技能目录 / 时间快照都记成
  `user/message`，只有 `source.kind === 'user'` 才是人打的字
  （`conversation-nodes/message.ts:79`）。按事件类型认角色会让一段
  "Current runtime context…" 冒充用户气泡（2026-10-20 隔离实例真机复现，一条会话里
  冒出三条"用户消息"）。缺 `source` 的 v3 形状按用户消息处理 —— 反向错法会藏掉人话。

### 有意偏离（每条都不得"顺手改回去"）

| 偏离 | 理由 |
|---|---|
| 折叠行高 36（DSH 24） | 触屏命中区；DSH 的 24 是桌面鼠标行高 |
| 折叠行右侧恒显 chevron（DSH 只在 hover 时把前导图标换成 chevron） | 触屏没有 hover，不画出来就没人知道能展开 |
| 折叠行**没有**卡片边框/底色 | 与 DSH 一致（原实现多了一层 `layer1` 卡片，视觉上冒充工具卡） |
| 标题上边距 24 / 下 8（DSH 32/16） | 32px 是文档级留白，手机聊天里会把一条回复拉散 |
| 代码块正文 12/18（DSH 11/19） | 手机上 11px 代码太小；与正文 14 的比例仍接近 DSH |
| 工具卡正文不带 `输出` gutter 标签（DSH `.ioLabel`） | 那一列要吃掉 14+ 横向空间；卡片标题行已说明是哪个工具 |
| 表格单元格首/末列不归零内边距、窄表不铺满、无 `min-width:100px`/`max-width:30vw` | `tableCellsPadding` 与列宽策略在 flutter_markdown 里都是整表一个值，做不到按列/按表分支 |
| 行内 HTML 归一成 Markdown（DSH 显示标签原文） | Flutter 没有 HTML 注入面；`<br>/<b>/<i>/<code>` 四种确定等价，其余去标签保文字（宁可丢样式，不丢文字） |
| 用户消息没有 `@文件` / `/skill` 引用 chip | 那是 `ui-reference` / `ui-skill` 的匹配器与写面，未接；正文仍是纯文本，与 DSH 同形 |
| **高亮语言集 28 种**（DSH 只高亮 ts / bash / json） | 数据源相同（围栏的 CommonMark info string），差别只在"认不认这门语言"：```` ```rust ```` / ```` ```python ```` 这类块桌面报「代码块」+ 单色，手机报语言名 + 彩色。手机上多认几种是**渲染能力**的扩展，不动数据面、不动标签判据的结构（判据仍是 `supportsHighlighting` 的同一条）。清单在 `app/lib/ui/dsh_code_highlight.dart:55-82`；取舍见 `.agents/notes/implemented/2026-10-29-code-highlight-language-set-wider-than-desktop.md` |

---

## 5. 三端能力包(平台差异只住在这里)

```text
app/packages/
├── secure_store/      接口:read/write/delete(32 字节主种子 + 刷新令牌)
│   ├── secure_store_ios/       Keychain:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
│   │                           (Curve25519 无法进 Secure Enclave,只能软件密钥;可选生物识别门控)
│   ├── secure_store_android/   Keystore:强绑定 + 设备解锁门控(可用时优先 StrongBox)
│   └── secure_store_ohos/      自写 ArkTS platform channel 接 HUKS:
│                                 generateRootKey / deriveChildKey / 生成 X25519+Ed25519
│                                 失败降级:HUKS AES 密钥包裹主种子(绝不落 preferences 明文)
├── notify/       投递与分类、通知操作按钮(iOS action / Android action / 鸿蒙 wantAgent)
├── live_surface/ iOS Live Activity(≤4 KB,按状态变化推送,不按固定频率)
│                 Android 提升通知(仅本机发起的任务)、鸿蒙 不做跑动中进度
└── keepalive/    Android 前台服务(用户主动开启,尽力而为,不作为必达路径)
```

接口只暴露语义(`start(ProgressSnapshot)` / `update(...)` / `end(...)`),平台细节不出包。

---

## 6. UI 接线点(逐屏 → 数据源)

| 界面(`design-and-tech-plan.md` §7) | 数据源 |
|---|---|
| 会话列表 | `session.list` 快照 + `pending.changed` 计数 |
| 会话详情 · 对话 | `sessionUpdates(sid)` → items;`live` 累加器;输入栏走 `outbox` |
| 会话详情 · 轨迹 | items 内的 step/usage 投影(与对话同一份 items,不额外请求) |
| 状态 chip → 三个 sheet | 同一 items 的统计投影(本地算,不请求) |
| 右抽屉(文件 / 任务 / 子代理) | items 的 tool/diff 投影 + `job.list` / `job.follow` 订阅流;子智能体面板是**目录树**(直接子级 + 展开才懒加载,`subagentCatalog`),行带活动态 / `title · mode · activity` / token / 真实耗时;点行**进入子会话**(同 DSH `openChild`,`ui-subagent/src/client/index.ts:61-63`),子会话顶栏是 `←` + 当前子级标题(点开 = 切换面板);**父级来自 `session.list` 行的 `parentSessionId`**(别名形式,老连接器才退到目录扫描 / 导航记忆),一次性 / 模式未知的输入栏换成 54px 横向只读框(`SubagentReadOnlyComposer`);规格见 `subagent-page.md` |
| 审批 / 提问接管输入栏 | 待处理项随 `ev` 帧到达(**没有 `interaction.list`**,见 `remote-channel.md` §6.3);审批与提问都转,连接器"不参与"时**委托**(`next`),手机这边的卡能不能答由 `interaction.respond` 的结果决定 |
| 设置页 | `repo.info` 的 `caps` 决定可用性;`settings.*` / `credentials.set\|unset` |
| 设备与连接状态 | `presence` + 本地 `ConnectionState` |

**能力门控**:所有"电脑侧可能不支持"的按钮由 `caps` 决定置灰,不用发请求试探(避免错误码驱动 UI)。

### 6.1 换了网络连不上时

电脑换网络(DHCP 换段、家 ⇄ 公司)后,手机里存的地址会**全部**拨不通。两种出口:

1. **自动**:`dialOrder` 每次都把整张表试一遍(记住的 → 同网段 → 用户顺序),`endpoint.describe`
   在**连上之后**学新地址并写回表 —— 所以同一次会话内换网能自愈,前提是**有一条能通**。
2. **手动**:连接操作 sheet 的「手动填写电脑地址」→ 填 `ws://<局域网地址>:8790`,
   **只加进表、不自动拨**;用户在「换个连接方式」里选它才连(与设置页「添加端点」同一个
   对话框、同一句承诺)。配对凭据与地址无关,**不需要重新扫码**。

   对话框里**直连是填、中转是选**:中转那一栏给「内置中转 / 自定义」二选一,默认落在
   内置(`kBuiltinRelayUrl`,构建期 `--dart-define=BUILTIN_RELAY` 可换),地址就写在选项上 ——
   用户换了自己的中转之后,想用回内置的那条是点一下,不用背域名。

### 6.2 端点的身份、归属与拨号次序

| 面 | 规则 | 出处 |
|---|---|---|
| 身份 | `id = hostId|url`（没有归属时退回 url，见 `endpointIdOf`）；`kind` / `label` / `manual` 是属性，不是身份 | `core/endpoint.dart` 的 `Endpoint` |
| 归属 | 连接器自报的端点盖上**当前配对那台电脑的 Ed25519 公钥**（`pcSignPubHex` → `hostId`，客户端字段，不上线）；**换了一台电脑后，旧电脑报过的自动条目直接剪掉**，手填的永不动。用公钥不用 `pcId`：后者是连接器 id，默认 `"local"`，两台电脑会撞 | `data/endpoint_book.dart` 的 `mergeDiscoveredEndpoints`、`.agents/notes/implemented/2026-10-29-endpoint-host-scoped-pruning.md` |
| 按 id 记账的四样 | `hidden` / `succeeded` / 拨号记录（`attempts`）/ "记住的那条"（`remembered`）都按 `Endpoint.id`；**同一个 url 属于两台电脑时互不继承**（B 不会因为 A 成功过而保留 A 的死地址） | `core/endpoint.dart` 的 `endpointIdOf` / `EndpointMeta`、`data/endpoint_book.dart`、`.agents/notes/implemented/2026-10-30-endpoint-and-ui-state-host-scoping.md` |
| 拨号次序 | 记住的那条 → 同 /24 的 → 本机其余 → **别的电脑报的** → **冷却中的**；**不删、不永久降权**（降权等于"出门一次就再也回不到直连"） | `core/endpoint.dart` 的 `dialOrder`、`core/endpoint_transport.dart` |
| 拨号方式 | **竞速**：按表顺序错开 250ms 启动，第一个建立 socket 的赢，其余立刻关（**不进握手**）。中转端点同一时刻只让一条在飞（`replaced` 语义会顶掉前一条），直连可并发。总耗时 ≈ 单条上限 + 错开，不随端点条数线性增长 | `core/endpoint_transport.dart`、`.agents/notes/implemented/2026-10-30-dial-racing-and-buffer-trim.md` |
| 失败冷却 | 最近一次拨号**失败**且距今 < 60s 的端点排到队尾（**连"记住的那条"也不例外**）；窗口一过自动回原位；成功即清。记录带时间戳（`EndpointAttempt.atMs`），**没有时间戳的旧记录不参与冷却**（不猜）。60s 的取值依据：直连 3s / 中转 10s 超时 + 连接层 10s 退避上限 ≈ 几轮重试 | `core/endpoint.dart` 的 `isCooling` / `kEndpointCooldown` |
| 建连超时 | 直连 3s、中转 10s —— 直连是同一局域网（死的地址立刻知道），中转可能在公网 | `platform/transport_factory.dart` |
| 全失败时的语义 | 抛一条 `TransportException`，**只带最后一个端点的原因与 code**；前面几条为什么失败不逐条上报（界面显示一条即可，逐条要另开面） | `core/endpoint_transport.dart` |
| 明文边界 | 公网必须 `wss`；明文 `ws` 只放行非公网（回环/私网/CGNAT/link-local/ULA/IPv4-mapped）。IPv6 按前两字节分类，`::ffff:c0a8:101` 这种十六进制映射会被判成公网（**宁可严一格**） | `core/endpoint.dart` 的 `checkedRelayUri` / `isPrivateOrLoopback` |
| 中转地址的规范形状 | **只留 `scheme://authority`**（路径/参数丢掉）：路径由协议拼（`/ws-ticket`、`/ws/device`）。电脑侧配置与二维码里的 `wss://host/ws/connector`（那是连接器拨的路径）与根地址是**同一台**中转 —— 不折叠就是表里两条、竞速互踢。直连**不**规范化（可能挂在反代子路径后） | `core/endpoint.dart` 的 `canonicalEndpoint`、`data/endpoint_book.dart` 的三个入口 |
| 同网段判断 | **只对 IPv4 生效**：`subnetScore` 对 IPv6 与域名一律返回 0（"不猜"）。所以 IPv6-only 或 mDNS 名字的场景没有"同网段优先"，退化成"记住的 + 用户顺序" | `core/endpoint.dart` 的 `subnetScore` / `_ipv4OfUrl` |

**adb 转发不是端点的一种**：它只是把手机的 `127.0.0.1` 接到电脑，回环地址本来就落在
"非公网、允许明文"那一档；真实用法是**公网中转或局域网直连**。端点表里出现回环地址
只可能是手填（或手机被改过路由，见 `tools.md` 那条劫持判据）。

**明文分两档放行**（`core/endpoint.dart` 的 `checkedRelayUri`，两个开关互不替代）：

| 档 | 判据 | 谁给 | 用于 |
|---|---|---|---|
| 非公网 | `ws://` 且主机是回环/私网/CGNAT/link-local/ULA | 装配层常开（`allowInsecureLocal: true`） | 局域网直连、组网（Tailscale 100.64/10） |
| 公网 | `ws://` 且主机是公网地址 | **用户显式确认**：手机侧 `net.allow_plaintext_public`、电脑侧 `allowInsecurePublic`（两端各判各的，互不替代） | 自部署中转、暂无域名/证书 |

公网那一档的确认点有三个：手机手填端点对话框里的勾选、手机配对页确认卡上的警告+确认
（那一步会把电脑身份摆出来）、电脑侧「手机」面板 →「连接」卡里的勾选。
**默认不开**，且确认文案必须写明"元数据可见"。电脑侧同一个判据在
`connector/src/transport/relay-url.ts` 的 `relayUrlOf`（写入前校验，schema 不管这件事）。
`wss://` 任何主机始终放行（域名或 IP 都行）。

中转**自己不终结 TLS**（`relay/src/server.ts` 用 `node:http` + `WebSocketServer`）：
要 `wss` 就得由前置反向代理（Caddy/nginx）持证书 —— 域名用 Let's Encrypt，
纯 IP 可用 [Let's Encrypt 2025 起的 IP 证书](https://letsencrypt.org/2025/01/16/6-day-and-ip-certs)
（6 天短期，需自动续期）或商业 IP 证书。手机侧没有"接受自签证书"的缝
（全仓无 `badCertificateCallback` / `SecurityContext`），自签要走就得改代码（钉指纹，尚未做）。

### 6.3 凭据：一台电脑一个槽

安全存储里的键是 `dsh.pairing.<hostId>.<field>`，外加 `dsh.pairing.active`（当前那台）；
`hostId` 是那台电脑的 Ed25519 公钥（`pcSignPubHex`，配对时钉死）。配对第二台是**新增槽**，
不覆盖第一台。端点表与路由记忆（`endpoints` / `endpoint_meta`）也在槽里，写回时按当前凭据的
`hostId` 定位（装配层 `main.dart` 的闭包）。

- **写**：先写完整槽、最后写 `active` —— 崩在中途时半个槽不会被选中。
- **读**：`load({hostId})` 不给就读 `active`；槽里必填字段缺一个就回 `null`（不拼半份）。
- **不迁移**：协议未发版，旧平铺键 `dsh.<field>` **不识别**（读到就当作没有，也不删）；`load()` 没有迁移步骤。
- **清**：`clear()` 只删这一台（当前槽），删的是当前那台时顺手清 `active`，**不自动挑另一台**；
  `clearAll()` 才是"撤销所有配对"。连接终态失败（身份被拒）走 `clear()`，
  用户在设置里"清除配对"走 `clearAll()`。

- **切换**：`activate(hostId)` 只写 `active`（槽不完整时抛，不让指针指向读不出的凭据）；
  `hosts()` 是列表的派生读（只列能用的槽，当前那台排最前），名字取槽里的 `host_name`
  （电脑自报的展示值缓存，读不到就显示 `hostId` 短码：前 6 + 后 4）。**没有"已配对电脑清单"这第二份真值**。

时机与代价见 `.agents/notes/implemented/2026-10-30-pairing-slots.md`。

### 6.4 切换电脑（N:M）

一台手机可以同时连多台电脑，一台电脑可以同时服务多台设备 —— **两个方向都不设人为上限**（同时用几台是用户的事）。手机侧的三条定案：

1. **切换 = 换凭据槽 + 重新装配**：`PairingStore.activate(hostId)` 改槽指针，再用那份凭据装配一个新的 `AppModel` 并 `start()`；旧实例与它的 socket 在这一步被 `dispose`（`app/lib/main.dart` 的 `_switchTo`）。`AppModel` 里**不存"当前是哪台"**，真值是凭据槽的 `active` + 装配层的 `_credentials`。
2. **切不过去就停在原地**：读槽失败或 `activate` 抛错时，`active` 与 `_credentials` 都没动过，旧那台照旧；装配成功但连不上，就停在目标那台的「未连接（原因）」，给「重试连接」与「切回上一台」两个显式出口。
3. **不自动挑**：没有"自动选一台能连的"这回事，用户点哪台连哪台。

**两台电脑的数据不混，靠清库**（当下事实）：`sid` 是各电脑独立分配的不透明别名，两台电脑可能撞名，所以装配时比对 `meta.local_items.host`，换了电脑就清掉本地条目（`main.dart` 的 `_scopeLocalItemsToHost`）。代价是切回去要**整段重刷信息流**。

> **目标（未落地）**：装配层按 `hostId` 持有一池 `AppModel`（切换不拆旧的），条目与水位按 `<hostId>/<sid>` 分域、切换不清库 —— 前提是清库这件事改成"按桶正写"（`schema.*` / `device.*` / `host.<id>.*` 三类主人各管各的，见 `ui-state.md` §2 与 §3）。在那之前，**当前实现会连 `device.*` 偏好一起清掉**，切电脑后主题/字号会回到默认 —— 这是已知缺陷，修法在 S2（把 `clear()` 从"清四张表"改成"只清这一台的会话缓存"）。

**时间预算**（方案决策 7 的表，每一层只有一个判据处）：

| 层 | 值 | 出处 |
|---|---|---|
| 单条直连 / 中转拨号 | 3s / 10s | `platform/transport_factory.dart` |
| **拨号总预算** | **15s**（到点抛失败，已成结论） | `core/endpoint_transport.dart` 的 `totalBudget` |
| 握手 / 首同步 / 请求与心跳 | 10s / 15s / 60s | 契约 §4.1、`core/handshake_driver.dart`、现有请求层 |
| 提示时序 | 2s 出阶段 → 8s 「网络很慢」 → 15s 出结论 + 手动重试 | `model/chat_item.dart` 的 `connectionHintAt`（**只负责文案**） |
| 结论之后 | 静默慢重试 60s ± 20% | `core/connection.dart` 的 `Backoff.nextSlow` + `sync_client_impl.dart` 的 `_onStateChanged` |

慢重试与快退避**共用同一份抖动算术**（`Backoff._jittered`），只是基准值与上界不同；
"给过结论"由 `SyncClientProbe.lastConnectGaveUp` 表达，界面停在「连接不上」而不是每轮跳一次
「连接中…」。取舍见 `.agents/notes/implemented/2026-10-30-device-switch-and-budgets.md`。

---

## 7. 测试策略

| 层 | 怎么测 |
|---|---|
| 纯 Dart 语义 | `flutter test`:直接跑 `protocol/fixtures` 的场景(用 `data/dto` 反序列化),断言与参考实现一致 |
| 密码学互操作 | `test/crypto_vectors_test.dart` 跑 `protocol/vectors/`(与 TS 侧同一批已知答案) |
| 状态机 | `sync_client_test.dart`:用假 transport 注入断连/乱序/空洞/快照分页,断言 §2.1 的状态迁移 |
| 存储 | `sqflite_common_ffi` 在桌面跑事务与迁移用例;断言"落盘后才发 `persisted`" |
| UI | widget test 覆盖"UI 永不闪空"与流式替换;真机验收锁屏与强杀 |
| 边界 | `node app/tools/verify-platform-boundary.mjs` |

**选型现状(2026-10-16 校准)**:

- Markdown 渲染:**已定** `flutter_markdown_plus`(唯一传递依赖 `markdown`,Dart 团队维护;`flutter_markdown` 已 discontinued)。选型表与理由见 `app/lib/ui/dsh_markdown.dart` 文件头。
- 代码块：**已照 DSH 的 `CodeBlock` / `CodeToolbar` 落地**头部工具条(语言标签 / 自动换行 / 复制;默认自动换行),见 `dsh_markdown.dart`。语法高亮走纯 Dart 的 `re_highlight`,认 28 种语言（比桌面的 ts/bash/json 宽，见 §4.1「有意偏离」），标签判据与桌面同构（认得报语言名、认不得报「代码块」），未知语言退纯文本。与 DSH 的两处差异：① 高亮在构建时算、token 不缓存（DSH 是首次进视口算一次并缓存，`ui-primitives/src/markdown/highlight.ts:286`、`useViewportHighlighting.ts:17,48`），见 §4 的"代码高亮开销"；② **换行开关的状态不跨重建**——块被列表回收后重建会回到默认（自动换行），因为 `_DshCodeBlock` 的 `_wrapped` 只活在 `State` 里，未接 `PageStorage`（2026-10-29 真机实测：滚出视口再滚回来，按钮回到「取消自动换行」）。
- 数学公式:**不做**。DSH 支持 `$…$` 与 ```` ```math ```` 围栏(KaTeX),手机侧没有纯 Dart 的等价物,而它是独立一块(不属"把 Markdown 渲染出来")。如实记在 `dsh_markdown.dart` 文件末。
- 图片:`cached_network_image` 不适用(内容不来自网络),用 `Image.memory` + 自建 LRU。
