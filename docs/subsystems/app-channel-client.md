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
| 代码高亮开销 | 只在条目首次可见时高亮一次并缓存 token 结果;不随流式每帧重算 |
| 长 Markdown | **不做段落切分**:查过 DSH,它也没有正文虚拟化/按段切,只在**流式期间冻结除末尾两块以外的块**(`packages/client/ui-chat/src/client/conversation-nodes/incremental.ts:9,38` 的 `UNSTABLE_TAIL_BLOCKS = 2`)⇒ 手机侧照同一条做"流式只重排末尾" |

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
| 右抽屉(文件 / 任务 / 子代理) | items 的 tool/diff 投影 + `job.list` / `job.follow` 订阅流 |
| 审批 / 提问接管输入栏 | 待处理项随 `ev` 帧到达(**没有 `interaction.list`**,见 `remote-channel.md` §6.3);本期只转**提问与计划审查**,审批等看护计时器实现后再开(§6.2.1) |
| 设置页 | `repo.info` 的 `caps` 决定可用性;`settings.*` / `credentials.set\|unset` |
| 设备与连接状态 | `presence` + 本地 `ConnectionState` |

**能力门控**:所有"电脑侧可能不支持"的按钮由 `caps` 决定置灰,不用发请求试探(避免错误码驱动 UI)。

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
- 代码块:**已照 DSH 的 `CodeBlock` / `CodeToolbar` 落地**头部工具条(语言标签 / 自动换行 / 复制;默认自动换行),见同文件。**仍未做**:语法高亮 —— 候选 `highlight`(纯 Dart);接的时候照 DSH 的三条纪律:**只支持 ts/bash/json**、**首次进入视口才高亮一次并缓存**、未知语言退纯文本(`packages/client/ui-primitives/src/markdown/highlight.ts:42,17`、`useViewportHighlighting.ts:48`)。
- 数学公式:**不做**。DSH 支持 `$…$` 与 ```` ```math ```` 围栏(KaTeX),手机侧没有纯 Dart 的等价物,而它是独立一块(不属"把 Markdown 渲染出来")。如实记在 `dsh_markdown.dart` 文件末。
- 图片:`cached_network_image` 不适用(内容不来自网络),用 `Image.memory` + 自建 LRU。
