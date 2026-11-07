/// 连接与订阅的唯一 owner（契约 §2.2、§5、§7）。
///
/// ## 为什么必须"一个 owner"
///
/// 连接、订阅、恢复、流控全部由本类持有，UI 只订阅它暴露的流 —— **不存在第二处重连逻辑**。
/// 分成两处（比如"网络层自己重连、页面层也重连"）必然导致两条连接同时存在，
/// 而症状是"有时候收到两次、有时候一条都收不到"，在真机上几乎无法归因。
///
/// ## 本层只做"接线"，不重新实现任何判据
///
/// 每个判据都已经在别处被单独测过，这里只负责按契约把它们接起来：
///
/// | 判据 | 出处 |
/// |---|---|
/// | 状态迁移白名单 | `connection.dart` 的 `ConnectionMachine` |
/// | 退避与抖动 | `connection.dart` 的 `Backoff` |
/// | 心跳与半开 | `keepalive.dart` 的 `Keepalive` |
/// | 握手三帧 | `handshake.dart` + `handshake_driver.dart` |
/// | 封箱与解箱 | `box.dart` |
/// | 流控窗口 | `flow.dart` 的 `SendWindow` |
/// | 恢复判定与拼接 | `recovery.dart` 的 `DeviceSession` |
/// | 写操作幂等 | `outbox.dart` |
///
/// 这一层如果自己再写一遍某个判据，就会出现**两个来源** —— 而那正是本项目反复抓到的
/// 一类 bug（见 `tools.md` 的 Pitfalls）。
library;

import 'dart:async';

import 'box.dart';
import 'connection.dart';
import 'crypto.dart';
import 'errors.dart';
import 'handshake_driver.dart';
import 'history_page.dart';
import 'host_rpc.dart';
import 'items.dart' show EventIdReaders;
import 'job.dart';
import 'keepalive.dart';
import 'live_message.dart';
import 'outbox.dart';
import 'recovery.dart';
import 'transport.dart';

/// App 前后台状态（契约 §2.2、§9）。
///
/// **它决定两件事**：要不要维持连接（后台主动断开并停表）、要不要发心跳。
enum AppState {
  /// 前台：维持连接、发心跳、可重连。
  foreground,

  /// 后台：主动断开、停表、不发心跳（三端都不做后台长连接，见契约 §13）。
  background,
}

/// `SyncClient` 的对外面（`app-channel-client.md` §2 的签名级契约）。
abstract interface class SyncClient {
  /// 开始连接（`idle → connecting`）。**幂等**：已在连接中或已服务时不重复建。
  ///
  /// 与 [setAppState] 分开是刻意的：装配点决定"何时开始"，前台/后台决定"要不要维持"。
  /// 两者合成一个入口的话，"切后台再回前台"与"首次启动"会走同一条路，
  /// 而它们该做的事不同（前者要重连，后者要建连）。
  Future<void> start();

  /// 连接状态流（`idle` / `connecting` / `handshaking` / `serving` / `backoff`）。
  ///
  /// 它是**广播**流：UI 的多个部件都要看连接状态，而单订阅流会让第二个监听者抛错。
  Stream<ConnectionState> get connection;

  /// 某会话的条目更新（增量与快照收口都从这里出）。
  Stream<SessionDelta> sessionUpdates(String sid);

  /// 订阅一个会话。
  ///
  /// **水位由连接层自己带**（`DeviceSession.sinceOf` = 最近一条落盘事件的 `seq`）：
  /// 电脑侧按它决定"只补之后那一段"还是"整窗重放"（契约 §5.7 的 `session.subscribe`）。
  /// 调用方**没有**这个参数的入口 —— 谁手里有内容只有连接层知道，
  /// 让它当参数，就是给"手机声称自己有到 N、其实界面是空的"开一个口子。
  ///
  /// 返回**基线水位与"还有没有更早的历史"**（契约 §3.1：`session.subscribe` 的回包）。
  /// `hasMore` 为真时更早的历史在电脑侧还有，UI 滚到顶要调 [page] 去翻 ——
  /// 不翻的话，手机上只有电脑侧那一个窗口（DSH 的 `DEFAULT_MAX_MESSAGES = 50`，
  /// `packages/api/session-controller/src/history.ts:38`），
  /// 于是"历史上明明有 20 轮，手机上只看到最近 3 轮"。
  ///
  /// 订阅集会跟着连接走：每次进服务态都用 `sync.hello` 把它**整份**重新声明一次
  /// （契约 §5.4：手机回到前台时要恢复的是"所有会话"，不是一个）。
  Future<SessionAnchor> subscribe(String sid);

  /// 退订一个会话。
  Future<void> unsubscribe(String sid);

  /// 往前翻一页历史（契约 §5.7 的 `session.page`）。
  ///
  /// [beforeSeq] 是切点：拿**严格早于**它的那一页。翻页时传当前最早一条的 seq。
  ///
  /// **窗口照 DSH Web**（`client/sessions/session.ts:54` 的
  /// `HISTORY_PAGE_OPTIONS`）：`maxMessages` 500 + `minMessages` 50 +
  /// `minTurns` 2 —— 一页至少 50 条消息与 2 个 turn 开始，上限 500 条消息。
  /// **按轮次边界切**，所以一轮不会被劈成两半（`history.ts:405-411`）。
  ///
  /// 电脑侧**不猜水位**：切点拿不到时回 `session/window-missed`（§3.1），
  /// 那时手机该重新订阅走快照，而不是当"没有更多了"。
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = kHistoryPageMaxMessages,
    int minMessages = kHistoryPageMinMessages,
    int minTurns = kHistoryPageMinTurns,
  });

  /// 这个会话还有没有更早的历史。
  ///
  /// 来源是 `sync.hello` 的应答（`connector/src/handlers.ts:767` 起，
  /// `{sessions: [{sid, since, hasMore}]}`）—— 那是**批量** anchor，
  /// 而 `session.subscribe` 的单条应答手机侧不读（它走 outbox，
  /// 见 `sync_client_impl.dart` 的 `subscribe`）。
  ///
  /// **没收到应答时是 `false`**：那意味着"不知道"，而不是"确定没有"。
  bool hasOlderHistory(String sid);

  /// 补取一条被 `refetch` 标记替代的大条目（契约 §5.7 的 `session.refetch`）。
  ///
  /// 翻页时电脑侧对**单个条目 > `refetchThresholdBytes`（默认 1 MiB）** 的
  /// 只推一个标记 `{kind:'refetch', seq, bytes}`，内容要按需来取
  /// （`connector/src/session-page.ts:103-110` 出标记、`:115-139` 补取）。
  /// **不补取就是会话里一个静默的洞**：不报错、不缺页，只是少一条。
  ///
  /// 失败要如实抛（`ProtocolException`）—— 上层据此把这一页判为失败、
  /// 不落半页（`AppModel.loadOlderHistory`）。**没有"退化的成功"**：
  /// 返回一条编造的事件比返回失败更糟。
  Future<SessionEvent> refetch({required String sid, required int seq});

  /// 一页历史的消息上限（照 DSH Web 的 `HISTORY_PAGE_OPTIONS.maxMessages`）。
  static const int kHistoryPageMaxMessages = 500;

  /// 一页历史至少要这么多条消息才肯切（照 DSH Web 的 `minMessages`）。
  static const int kHistoryPageMinMessages = 50;

  /// 一页历史至少要覆盖这么多个 turn 开始才肯切（照 DSH Web 的 `minTurns`）。
  static const int kHistoryPageMinTurns = 2;

  /// 调一个方法（契约 §5.7 的封闭集）。
  ///
  /// [requestId] 是幂等键：带它的调用**先落盘再发送**（§5.6）；不带它的走即时请求
  /// （只读方法不需要幂等）。
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  });

  /// 任务输出帧流（`job` 帧，契约 §5.3）。**广播流**：任务面板与角标都要听。
  ///
  /// 取代 `SyncClientProbe.jobFrames` 那个列表 —— 它是没有任何消费者的死 API，
  /// 而任务面板接不上正是因为它：让 UI 自己解析明文 JSON，等于让
  /// "帧里是什么"有第二个答案。解析只发生在 `sync_client_impl`（那里本来就有明文），
  /// UI 拿到的是 `core/job.dart` 的 `sealed class JobFrame`。
  Stream<JobFrame> get jobUpdates;

  /// 会话运行态流（`status` 帧）：宿主 `api-session/status` 的原样转发。
  ///
  /// 这是"这个会话在不在跑"的**唯一真值来源**（`SessionSummary.running` 只是初值）。
  /// 它取代了手机侧原来那套"数 `turn/start` / `turn/end` + 重连重建 + 轮次代号"的
  /// 自建状态机 —— 宿主本来就有这条推送，DSH 的浏览器吃的就是它
  /// （`packages/api/session-controller/src/client/index.ts:118-119`）。
  Stream<SessionStatus> get sessionStatus;

  /// **宿主状态变更提示**流（`host` 帧，契约 §5.9）。
  ///
  /// 载荷只有 key（方法名）：电脑侧改了模型 / 权限档 / 设置 / 标题 / 任务表时，
  /// 它来说"这些快照可能过期了"。**不带值** —— 值永远由快照方法给，那是宿主的权威。
  ///
  /// 这一层只做**形状**（`keys` 是字符串数组、`sid` 可选），不认识哪个 key 是哪个方法：
  /// 那张表在 `data/host_state.dart`（登记表），合并与丢弃也在那里。
  ///
  /// Note: 这条通道为什么存在、触发点为什么全在宿主事件上 —— 见
  /// `.agents/notes/implemented/2026-10-31-host-state-sync.md`。
  Stream<HostStateChanged> get hostStateChanges;

  /// 前后台切换。
  Future<void> setAppState(AppState state);

  /// **立刻重拨**：断开当前连接并按新的路由意图重新建连。
  ///
  /// 与 [start] 的区别：那个是"从没连过才开始"，已经在服务态时**什么也不做**；
  /// 这个是"用户说换一条"，正在服务的连接也要收掉重来。
  ///
  /// 用途只有一个：设置页的**点名连接**（"用这个端点连"）。自动队列不需要它 ——
  /// 那条由连接层自己的退避与 [start] 驱动，主动插一脚会让两套重连逻辑打架。
  ///
  /// **幂等**：连拨两次只会留下一条连接（先断后建，第二次断的是第一次建的那条）。
  ///
  /// **默认实现退化成 [start]**（而不是抽象方法）：它只被设置页的点名连接用到，
  /// 而全仓有 24 个 `SyncClient` 替身（几乎都只测状态/投影，不关心拨号）。
  /// 把它们全部补一遍是纯噪声，且下次再扩接口还要再改 24 处。
  /// **真的需要主动重拨的只有 `_SyncClient` 一处**（它 override 了这个默认实现）。
  Future<void> reconnect() => start();

  /// 当前连接状态（同步读，UI 首帧用）。
  ConnectionState get state;

  /// 关闭（释放定时器与连接）。**幂等**。
  Future<void> close();
}

/// 「链路开关」—— 用户主动断开 / 恢复（`AppModel` 经能力判定使用）。
///
/// **不塞进 [SyncClient]**：全仓二十多个替身是 `implements SyncClient` 的，
/// 加一个抽象方法就得改二十多处，而它们只测状态与投影、根本不关心断开语义。
/// 用能力接口（与 `SyncClientProbe` 同一个手法）比"默认实现"更省，也不说谎：
/// 不支持就是没有这个能力，调用方按 `is` 判定（见 `AppModel.disconnectLink`）。
abstract interface class LinkControl {
  /// 断链并**停止自动重连**，直到 [SyncClient.reconnect] 被显式调用。
  Future<void> disconnect();
}

/// 诊断面：**不参与产品逻辑**，只给测试与日志用。
///
/// 单独一个接口而不是塞进 [SyncClient]：UI 不该看到"收到的帧列表"这种东西
/// （它会诱使界面层自己解析帧，而那正是分层要防的）。测试按需转成这个类型。
///
/// **配对帧不在这里**：配对走的是自己的受限通道（`core/pairing_channel.dart`），
/// 那条连接与业务连接不是同一条 —— 让业务客户端"顺手收集配对帧"是 v1 的旧形状。
abstract interface class SyncClientProbe {
  /// 收到的任务输出帧（`(帧头, 明文)`）。
  List<(Map<String, Object?>, String)> get jobFrames;

  /// 收到的 `presence` 帧。
  List<Map<String, Object?>> get presenceFrames;

  /// 最后一次协议错误。
  ProtocolException? get lastProtocolError;

  /// 判定为半开时已沉默多久；没判过是 `null`。
  int? get lastHalfOpenSilentMs;

  /// 上一次传输关闭的码；没有过是 `null`。
  ///
  /// 与 [lastProtocolError] **不是一回事**：那个是"我们主动拒了一帧"，
  /// 这个是"连接被关了"（对端关的、或本端关的）。断开的三种来源必须能分开，
  /// 否则真机上只能看到"反复重连"而没有任何原因。
  int? get lastCloseCode;

  /// 上一次传输关闭的理由（WebSocket 的 reason 字段）；没有是 `null`。
  String? get lastCloseReason;

  /// 上一次握手失败的原因（如 `internal：handshake-timeout`）；没有是 `null`。
  ///
  /// **这是第四条关闭路径，也是原先唯一不留声的那条** —— 真机上"每 10 秒重连"
  /// 正是走它（握手超时）。断开的四种来源（协议错误 / 半开 / 对端关闭 / 握手失败）
  /// 必须能分开，否则界面上只剩"列表是空的"。
  String? get lastHandshakeFailure;

  /// 当前在途请求数（UI 可据此显示"正在等待应答"）。
  int get pendingCalls;

  /// 上一次连接收口时被拒绝的在途请求数；没收口过是 `null`。
  ///
  /// 它值得暴露：**被拒绝的请求数是"这次断连伤到了什么"的唯一证据**。
  /// 没有它，一次断连只留下"连接状态变了"，而"有几个请求被取消"无从得知。
  int? get lastRejectedCalls;

  /// 上一次落盘失败；没失败过是 `null`。
  ///
  /// 它值得暴露，理由同上但更严重：**落盘失败的表现是"数据少了一段"**，
  /// 而不是任何用户可见的错误。没有这个字段，那条失败只留在日志里。
  Object? get lastPersistError;

  /// 上一次建连失败是否是**终态**（身份不被认，连接层**不再退避重连**）。
  ///
  /// 与 [lastProtocolError] 合起来看：`true` 时上层该按那个错误的
  /// `clientAction` 处置（当前只有 `rePair`：清本地凭据 + 回配对页），
  /// 而不是等连接层自己退避 —— 退避对"电脑不认本机"毫无意义，
  /// 只会每次都拿到同一个 401，用户永远卡在"重连中…"（议题 2）。
  ///
  /// `false` = 连接层会自行退避重连，上层无动作。
  bool get lastConnectWasTerminal;

  /// 连续失败太多次，连接层**已经停止自动重连**。
  ///
  /// 电脑关机 / 中转挂了时，无限重避意味着用户永远看着一个转圈的东西而没有结论
  /// （2026-10-15 真机反馈）。到阈值就停：界面说「连接不上」+ 给手动重试，
  /// 下一次回前台仍会再试一轮。
  bool get lastConnectGaveUp;

  /// 已声明的订阅集（**只有 `sid`**）—— `sync.hello` 会把它整份重新声明（契约 §5.4）。
  ///
  /// 水位不在这里：它属于连接状态（[subscribe] 的说明），而这份声明只回答
  /// "用户此刻打开着哪几个会话"。
  ///
  /// 暴露给测试与诊断：**断线之后 UI 不会重新 `subscribe`**（用户没有重新点开），
  /// 于是"恢复"只能由持有连接的这一层发起。看不到这份声明，就无法断言它真的发过。
  Set<String> get declaredSessions;

  /// 已发出的请求信封（**明文**）。
  ///
  /// 线上的 `box` 是密文，于是"我们到底发过哪个方法"在诊断面上完全看不出来 ——
  /// 而这一类问题（订阅发了但电脑不认、幂等键漏了）只能靠它查。记在封箱之前，
  /// 所以它是真发出去的那些（最多最近 64 条）。
  List<Map<String, Object?>> get sentRequests;
}

/// 订阅的回包：基线水位 + "还有没有更早的历史"（契约 §3.1）。
///
/// 电脑侧一直在发这两个字段（`connector/src/session-subscriptions.ts:80-85` 的
/// `SessionSubscriptionReply`），而手机侧**一度把整个回包丢掉**
/// （`subscribe` 返回 `Future<void>`）—— 于是"还有更早的历史"这件事
/// 手机上从来不知道，历史永远只有电脑侧那一个窗口。
class SessionAnchor {
  const SessionAnchor({required this.since, required this.hasMore});

  /// 基线水位（开启帧的 `cursor`，**包含式**切点）。
  final int since;

  /// 还有更早的历史（为真时该调 [SyncClient.page]）。
  final bool hasMore;
}

/// 一页历史（契约 §5.7 的 `session.page` 回包）。
class SessionPage {
  const SessionPage({
    required this.events,
    required this.hasMore,
    this.failure,
  });

  /// 这一页的**持久**事件（按 seq 升序，严格早于请求的 `beforeSeq`）。
  final List<SessionEvent> events;

  /// 还有更早的（为真时可以用这一页最早的 seq 继续翻）。
  final bool hasMore;

  /// 翻页失败的原因（`session/window-missed` 等）；`null` = 成功。
  ///
  /// **不当成"没有更多"**：契约 §3.1 给 `session/window-missed` 的客户端动作是
  /// 「重新订阅走快照」。把它当 hasMore=false 会让用户以为"历史就这么多"。
  final String? failure;
}

/// 一次会话更新（`sessionUpdates` 的元素）。
///
/// ## 为什么带的是**事件**而不是"条目"
///
/// 最初的版本只带 `ItemRecord`（`itemId` / `text` / `seq`），而那是**不够的** ——
/// 实测接线时才发现：`data/projection.dart` 要把事件投影成界面条目，
/// 而它需要事件的 `type` 与 `data`（"这是消息还是工具调用？内容是哪个字段？"）。
/// 只带 `text` 等于在 `core/` 里就把语义丢了，而那正是"UI 层各自去猜事件类型"的开端。
///
/// 所以这里带 [SessionEvent]：**原始事件 + 已推导的 `itemId`**。
/// `itemId` 的推导留在 `core/`（契约 §5.2 的规则只有一处），
/// 而"渲染成什么"交给上层 —— 分工就在这条线上。
class SessionDelta {
  const SessionDelta({
    required this.sid,
    this.events = const [],
    this.liveMessage,
    required this.transient,
    this.outcome,
    this.reason,
  });

  final String sid;

  /// 这一批**持久**事件（`ev` 帧）。快照收口时是整表。
  final List<SessionEvent> events;

  /// 当前**流式**内容（`live` 帧累加器的内容）；`null` = 这一批没有流式更新。
  ///
  /// 它**不在 [events] 里**，因为两者是不同性质的东西（契约 §3 的术语表）：
  /// 持久事件有稳定的 `itemId` 与会话 `seq`，而流式 chunk 没有 ——
  /// 它只属于"当前这次 assistant 尝试"，会被随后到达的持久
  /// `assistant/message` **整体替换**（`app-channel-client.md` §2.2：以持久为准）。
  ///
  /// 混进 [events] 会让 UI 需要"从 itemId 猜这是不是流式内容"，而那个判据
  /// 迟早写歪；分开之后"持久"与"流式"在类型上就是两件事。
  ///
  /// **形状与持久条目一致**（思考一段 + 正文一段），见 [LiveMessage] 的文件头。
  final LiveMessage? liveMessage;

  /// 瞬时事实（不变量 I4：每次恢复都无条件回带）。
  final TransientFacts transient;

  /// 这次更新的来源（`delta` / `snapshot`）；快照分页的中间页不出流。
  final RecoveryOutcome? outcome;

  /// 快照原因（仅 `outcome == snapshot` 时有）。
  final SnapshotReason? reason;
}

/// 一条**会话运行态**（`status` 帧）：宿主 `api-session/status` 的原样转发。
///
/// 它不是条目、也不进 [SessionDelta]：运行态是瞬时事实（与 `presence` 同性质），
/// 没有 `seq`、不参与水位，重新连上时以最新一条为准。
class SessionStatus {
  const SessionStatus({required this.sid, required this.running});

  final String sid;
  final bool running;
}

/// 一条**宿主状态变更提示**（`host` 帧，契约 §5.9）。
///
/// 与 [SessionStatus] 同性质（瞬时事实、不进业务 `seq`、丢了不要紧），但内容更薄：
/// **只有 key，没有值**。`sid` 是会话级 key 的定向依据（帧头字段，不是载荷里的数据），
/// 宿主级 key 忽略它。
class HostStateChanged {
  const HostStateChanged({required this.keys, this.sid});

  /// 载荷 `{keys: [...]}`：要重取哪些快照（方法名）。
  ///
  /// **这里不筛**"我们认不认识这个 key"：认识哪些是 `data/host_state.dart`
  /// 的登记表与它的计数器的事，`core/` 只如实转达帧里说了什么。
  final List<String> keys;

  /// 帧头 `sid`；宿主级通知没有它。
  final String? sid;
}

/// 一条会话事件：**原始载荷 + 已推导的身份**。
///
/// 刻意不叫 `ItemRecord` 了 —— 那个名字描述的是"条目"，而这里装的是**事件**。
/// 两者在 `ev` 帧上恰好一一对应，但语义不同（条目是 upsert 后的结果，
/// 事件是产生它的输入）。名字混用会让后来者以为"同一件事有两个类型"。
class SessionEvent {
  const SessionEvent({
    required this.itemId,
    required this.type,
    required this.seq,
    required this.time,
    required this.data,
  });

  /// 稳定身份（契约 §5.2 推导，不变量 I9）。
  final String itemId;

  /// DSH 事件类型（`user/message` / `tool/call` / …）。
  final String type;

  /// 会话修订号（DSH 的 `seq`）。
  final int seq;

  /// 事件时刻（DSH 的 `time`；缺失时取 `seq`）。
  final int time;

  /// 事件载荷（原始 JSON 对象，**不由 `core/` 解释**）。
  final Object? data;
}

/// **落盘缝**：把一批事件交给本地库，成功后返回。
///
/// ## 为什么是窄接口，而不是直接用 `ItemStore`
///
/// `core/` 不该知道"条目怎么存、有几张表、schema 几版" —— 那些是 `data/` 的事。
/// 它只需要一个承诺：**"返回了，就说明这批在盘上了"**。
///
/// 这也让 `core/` 的单测不必起数据库：给一个记账用的假实现即可。
///
/// ## 契约（实现必须满足）
///
/// 1. **返回即落盘**。抛错即表示没落盘，调用方**不会**发 `persisted`。
/// 2. **幂等**：同一批写两次等价于一次（崩溃后重放是预期行为，§5.3）。
/// 3. **水位与内容同一个事务**（§5.3）：不能出现"水位到了 10、条目只到 7" ——
///    那个状态无法自愈（重连时手机会说"我到 10 了"，电脑就不再补 8~10）。
abstract interface class ItemPersister {
  /// 提交一批事件与随之推进的水位。
  Future<void> persist({
    required String sid,
    required List<SessionEvent> events,
    required int seq,
  });
}

/// `SyncClient` 需要的一切。全部注入，所以它可以脱离真机测试。
class SyncClientDeps {
  const SyncClientDeps({
    required this.transport,
    required this.handshake,
    required this.box,
    required this.outbox,
    required this.session,
    required this.history,
    required this.eventIds,
    required this.hostRpc,
    this.persistence,
    this.keepalive,
    this.backoff,
    this.now,
    this.schedule,
    this.newId,
  });

  /// 传输缝（真实 WSS 或测试替身）。
  final ChannelTransport transport;

  /// 握手驱动器（**发起方** = 手机）。
  final HandshakeDriver handshake;

  /// 封箱/解箱（每连接一把密钥）。
  final BoxCodec Function(SessionKeys keys) box;

  /// 写操作队列。
  final Outbox outbox;

  /// 本地会话状态（接收规则、快照拼接、水位）。
  final DeviceSession session;

  /// 翻页与单条补取的**读法**（`session.page` / `session.refetch`）。
  ///
  /// 线上形状只有 `wire/` 能断言，而"补取 + 按 seq 归位 + 记住 hasMore"要连接层的
  /// 状态 —— 两半各守一边，所以这里是个端口（`history_page.dart`）。
  /// **必填**：不给它就没有历史可翻，而"翻不了页"不该是一个静默的默认值。
  final HistoryReader history;

  /// 事件**身份字段**的读法（契约 §5.2 的推导规则在 `items.dart`，字段名在 `wire/`）。
  ///
  /// 收帧热路径用它：每条 `ev` 帧解出来的 [SessionEvent] 都带 `itemId`，
  /// 而后者的推导要读 `callId` / `toolCallId` / `approvalId` / `commandId`。
  /// **必填**：不给就没法给事件一个稳定身份。
  final EventIdReaders eventIds;

  /// 「读电脑侧 / 改电脑侧」的两个口（`host_rpc.dart`），**是个工厂而不是实例**。
  ///
  /// 为什么是工厂：能力属于**这一条连接**，而连接是 `createSyncClient` 拿 deps
  /// 之后才成立的（`this` 只能在那之后传出去）。实现只在 `wire/`，所以装配点给的是
  /// `WireHostRpc.new` —— 连接层因此不必 import `wire/`，而消费者照旧
  /// `hostRpcOf(client)` 就能拿到 `reads` / `writes`。
  /// **必填**：不给就是"这台电脑的只读面全读不了、写操作一个也发不出去"，
  /// 而那不是该静默发生的默认值。
  final HostRpcHolder Function(SyncClient) hostRpc;

  /// **落盘缝**（契约 §5.3：`persisted` 只在落盘成功后发）。
  ///
  /// `null` = 不落盘，此时 `persisted` 发的是"我处理完了"而不是"它在盘上了" ——
  /// **那在生产里是不可接受的**（水位超前于内容 ⇒ 崩溃后那段数据永久丢失，
  /// 因为电脑收到水位就裁掉了那边的缓冲）。
  /// 所以生产装配必须给；`null` 只给"不关心崩溃恢复"的单测用。
  ///
  /// 它是个**窄接口**而不是 `ItemStore`：`core/` 不需要知道条目怎么存、
  /// 存几张表 —— 它只需要"把这批交出去，成功后告诉我"。
  final ItemPersister? persistence;

  /// 心跳与半开判定。不给则用默认周期。
  final Keepalive? keepalive;

  /// 退避。不给则用默认（生产随机源）。
  final Backoff? backoff;

  /// 时钟（毫秒）。注入以便测试确定化。
  final int Function()? now;

  /// `setTimeout` 语义。**调用它得到取消函数**（`schedule(fn, ms)()` 取消）。
  ///
  /// 注入以便测试用假定时器在毫秒内跑完"退避 30 s"这类场景 —— 真的等 30 s
  /// 会让这组测试慢到没人跑。
  final void Function() Function(void Function() fn, int ms)? schedule;

  /// 生成帧 `id`。注入以便测试确定化。
  final String Function()? newId;
}
