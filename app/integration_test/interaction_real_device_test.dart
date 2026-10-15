/// **真机端到端**：「交互转手机」这条链在设备上的那一半。
///
/// ## 它验什么
///
/// `channel_e2e_test.dart` 证明**配对**在设备上通；这一条证明**配对之后**那条链通：
///
/// ```text
/// 配对 → 建连 → 握手 → sync.hello(前后台态 + 订阅集)
///       → session.list(遥控电脑看会话)
///       → session.subscribe(点开会话 → ev 流进来)
///       → session.prompt(发一句)
/// ```
///
/// 它与单测的分工：单测钉的是**判据**（presence 的四个时机、fail-closed 的形状、
/// 答案批次的形状）；这一条钉的是**两套独立实现真的接得上** —— 而接不上的症状是
/// "电脑在等审批、手机上什么都没有"，在单测里永远看不出来。
///
/// ## 为什么凭据不清掉
///
/// `channel_e2e_test.dart` 结尾 `PairingStore.clear()`（它验的是"令牌落进 Keystore"，
/// 清掉免得留下凭据）。这一条**必须保留凭据**：后面的建连用的就是它。
/// 所以这条用例自己负责收尾，且收尾也清掉。
///
/// ## 跑法
///
/// ```powershell
/// adb reverse tcp:8787 tcp:8787
/// adb shell svc power stayon true
/// $qr = '<出码命令给的那段 JSON>'
/// $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($qr))
/// cd app
/// flutter test integration_test/interaction_real_device_test.dart -d emulator-5554 `
///   --dart-define=DSH_QR_PAYLOAD_B64=$b64 `
///   --dart-define=DSH_TARGET_CWD='D:\sudy\myproject\dsh-mobile-test' `
///   --dart-define=DSH_TARGET_PROVIDER=lightvela-free
/// ```
///
/// `DSH_TARGET_CWD` 把靶子钉在专用工作区（`session.list` 的 `cwd`，连接器一直在发）；
/// `DSH_TARGET_PROVIDER` 只用于**排序**，不用于过滤 —— 新会话的 `modelSelection`
/// 投影给不出值，硬匹配会一个靶子都挑不到（见 `_targetRank`）。
///
/// **跑之前必须在电脑侧把靶子会话的权限档切成 `workspace-write`**
///（在它的输入框敲 `/permission workspace-write`）。`danger-full-access` 预设带的是
/// `approval/policy: never`，那种档下审批**根本不问**，探针直接跑成功，
/// 手机上永远没有卡。切完按帧解压它的会话日志，确认 `permission/preset` 与
/// `approval/policy` 两个字端真的换了（判据见 `docs/cookbook/`）。
///
/// 二维码是**一次性**的（5 分钟）：所以这条用例内部自己做两段配对，而不是依赖
/// 设备上已经有的凭据 —— 否则"上一次跑剩的凭据"会让用例假通过。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';
import 'package:dsh_mobile/core/outbox.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/sync_client_impl.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/interaction.dart';
import 'package:dsh_mobile/platform/http_sender.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/platform/sqflite_item_store.dart';
import 'package:dsh_mobile/platform/ticketed_transport.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _qrPayloadB64 = String.fromEnvironment('DSH_QR_PAYLOAD_B64');

/// 审批靶子必须落在哪个工作区（真机联调专用工作区）。
///
/// **不给就跑不下去**：满磁盘挑会话会把探针投进用户其他项目的会话
/// （2026-10-13 真机两次踩过），也会挑到工作区已失效的会话 —— 那种会话
/// `session.prompt` 照常落 `user/message`，而它的 agent 永远不起轮次，
/// 全程零痕迹。
const _targetCwd = String.fromEnvironment('DSH_TARGET_CWD');

/// 审批靶子必须用的渠道（免费渠道的 provider 名）。
///
/// 会话存着自己的模型选择；不是当前 profile 配的那条渠道就起不来。
const _targetProvider = String.fromEnvironment('DSH_TARGET_PROVIDER');

String get _qrPayload {
  if (_qrPayloadB64.isEmpty) return '';
  return utf8.decode(base64.decode(_qrPayloadB64));
}

/// 靶子工作区的判据。**空 define = 一个都不匹配**，不是"全都匹配"。
bool _isTargetWorkspace(SessionSummary s) =>
    _targetCwd.isNotEmpty && s.cwd == _targetCwd;

/// 靶子渠道的排序档位，越小越优先。
///
/// **不能做成"必须匹配"**：`modelSelection` 投影的初值是
/// `{lastUsed: null, pending: null}`（`model-selection-projection.ts:61`），
/// 而 `next = pending ?? lastUsed` —— 于是一条从没跑过轮次的新会话**投影给不出值**，
/// 连接器于是不发 `model` 字段，手机侧是 `null`。把它判成"不匹配"会让靶子
/// 一个都挑不到。
///
/// 所以分三档：**已知是免费渠道**最优；**不知道**次之（新会话，实际用
/// profile 的默认渠道）；**已知不是免费渠道**直接排除 —— 那种会话存着自己的
/// 模型选择，不是当前 profile 配的渠道就起不来（2026-10-13 第三次真机的线索）。
int _targetRank(SessionSummary s) {
  final provider = s.model?.provider;
  if (provider == null) return 1;
  return provider == _targetProvider ? 0 : 2;
}

/// 靶子/标记探针的共用排序：专用工作区优先，其次渠道档位，再其次从没跑过轮次。
///
/// **一个比较器供两处用**：步骤 ② 挑标记会话、步骤 ⑤ 挑审批靶子。两处各写一份
/// 就会出现"同一个偏好有两个真值"，改一处漏一处。
int _compareTargets(SessionSummary a, SessionSummary b) {
  final byWorkspace = (_isTargetWorkspace(b) ? 1 : 0).compareTo(
    _isTargetWorkspace(a) ? 1 : 0,
  );
  if (byWorkspace != 0) return byWorkspace;
  final byRank = _targetRank(a).compareTo(_targetRank(b));
  if (byRank != 0) return byRank;
  return (b.blank ? 1 : 0).compareTo(a.blank ? 1 : 0);
}

ChannelTransport _pairingTransport(String upgradeUrl) =>
    WebSocketTransport(WebSocketTransportOptions(url: upgradeUrl));

/// 记下每次 `send` 的返回值（2026-10-13 真机排查用）。
///
/// 为什么需要它：`core/_write` 把 `transport.send()` 的返回值丢掉了，而
/// "socket 没收下这一帧"与"发成功了"在诊断面上完全一样。包一层就能分开
/// "帧没出手机"（`send` 回 `false`）与"帧死在路上"（连接后来才断）。
class _RecordingTransport implements ChannelTransport {
  _RecordingTransport(this._inner);

  final ChannelTransport _inner;

  /// 按调用顺序的 `send` 返回值。
  final List<bool> results = <bool>[];

  @override
  bool send(String line) {
    final ok = _inner.send(line);
    results.add(ok);
    return ok;
  }

  @override
  Future<Stream<TransportEvent>> connect() => _inner.connect();

  @override
  Future<void> close() => _inner.close();
}

/// 失败时把两端状态一次打全（2026-10-13 真机排查用）。
///
/// 它要分开的两种失败：**帧没出手机**（传输的 `send` 回 `false`）与
/// **帧死在路上**（连接后来才断、或电脑侧把请求拒了）。`core/_write` 把
/// `send()` 的返回值丢掉了，所以没有 [_RecordingTransport] 这一层，
/// "帧没出手机"与"发成功了"在诊断面上完全一样。
void _dumpDiagnostics(
  String stage,
  String sid,
  AppModel app,
  SyncClientProbe probe,
  _RecordingTransport recorder,
) {
  debugPrint('=== $stage ===');
  debugPrint(
    'sid=$sid  connection=${app.connection}  诊断=${app.connectionDiagnosis}',
  );
  debugPrint(
    'closeCode=${probe.lastCloseCode}  closeReason=${probe.lastCloseReason}',
  );
  debugPrint(
    'handshakeFailure=${probe.lastHandshakeFailure}  '
    'halfOpenSilentMs=${probe.lastHalfOpenSilentMs}',
  );
  debugPrint(
    'protocolError=${probe.lastProtocolError}  pendingCalls=${probe.pendingCalls}  '
    'rejectedCalls=${probe.lastRejectedCalls}',
  );
  debugPrint('send 返回值(按序)=${recorder.results}');
  debugPrint('已发方法(按序)=${probe.sentRequests.map((e) => e['method']).toList()}');
}

/// 真网络 + `pump` 交替地等一个条件成立。
///
/// 两者缺一不可：只在 `runAsync` 里等，组件树不重建（`find` 永远看到点击前那一帧）；
/// 只用 `pumpAndSettle`，它等"没有待处理的帧"，而真网络期间页面一直在变。
Future<bool> _waitFor(
  WidgetTester tester,
  Future<bool> Function() done, {
  int rounds = 300,
  int stepMs = 100,
}) async {
  for (var i = 0; i < rounds; i += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: stepMs)),
    );
    await tester.pump();
    if (await done()) return true;
  }
  return false;
}

/// 给"电脑侧要先跑一个模型回合"的场景用更长窗口（默认 3 分钟）。
Future<bool> _waitForModel(WidgetTester tester, Future<bool> Function() done) =>
    _waitFor(tester, done, rounds: 900, stepMs: 200);

/// 等重放**落定**：条目数连续 [stable] 次（每次 200 ms）不变即认为静默。
///
/// 为什么需要它：订阅之后连接器会把整段历史重放给手机，而"放完了没有"没有信号。
/// 用"连续不变"而不是"等 N 秒"：后者在慢机器上会过早判定，而这里要的是
/// "**再没有新条目**"这个事实。
Future<bool> _waitForQuiet(
  WidgetTester tester,
  int Function() size, {
  int stable = 8,
}) async {
  var last = -1;
  var same = 0;
  for (var i = 0; i < 120; i += 1) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    final now = size();
    same = now == last ? same + 1 : 0;
    last = now;
    if (same >= stable) return true;
  }
  return false;
}

/// 页面上所有"（…）"形式的错误文案。
String _errorText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.contains('（') && s.contains('）'))
    .join(' | ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机：配对后建连 → sync.hello → 看会话 → 点开会话 → ev 进来 → 发一句', (
    tester,
  ) async {
    if (_qrPayload.isEmpty) {
      markTestSkipped('未提供 DSH_QR_PAYLOAD：这条用例需要一台在跑的中转与连接器');
      return;
    }
    // 靶子判据是**配置**，缺了就明说：静默退回"满清单挑一个"正是前两轮
    // 把探针投进别人会话的原因。
    expect(
      _targetCwd.isNotEmpty && _targetProvider.isNotEmpty,
      isTrue,
      reason:
          '必须给 DSH_TARGET_CWD 与 DSH_TARGET_PROVIDER（专用工作区 + 免费渠道），'
          '否则靶子会挑到用户的其他会话上',
    );

    // ---- 第一段：清掉旧凭据后走两段配对（凭据**保留**给后面用）----
    await PairingStore.clear();
    PairingResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: PairingPage(
          send: createHttpSender(),
          transportFor: _pairingTransport,
          allowInsecureLocal: true,
          onPaired: (result) async {
            captured = result;
            await PairingStore.save(
              PairedCredentials(
                relayUrl: result.offer.relayUrl,
                pcSignPubHex: result.offer.pcSignPubHex,
                pcDhPubHex: result.offer.pcDhPubHex,
                pairingId: result.pairingId,
                masterSeedHex: result.masterSeedHex,
                devSignPubHex: result.devSignPubHex,
                devDhPubHex: result.devDhPubHex,
                deviceToken: result.deviceToken,
                refreshToken: result.refreshToken,
                pcId: result.pcId,
                devId: result.devId,
              ),
            );
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), _qrPayload);
    await tester.tap(find.text('连接电脑'));
    final ready = await _waitFor(
      tester,
      () async => find.text('通道已就绪，等待你确认').evaluate().isNotEmpty,
    );
    expect(ready, isTrue, reason: '受限通道应建起来；页面错误：${_errorText(tester)}');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并配对'));
    final paired = await _waitFor(
      tester,
      () async => find.text('配对成功').evaluate().isNotEmpty,
    );
    expect(paired, isTrue, reason: '提交后应拿到回执；页面错误：${_errorText(tester)}');

    // 第三段：点「完成」才落盘并建连（`onPaired` 在那一刻回调）。
    await tester.ensureVisible(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (captured == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expect(captured, isNotNull, reason: '点"完成"之后 onPaired 必须回调');
    await tester.pumpAndSettle();

    // **等凭据真的落进安全存储**，不能只看 `captured`：`onPaired` 在最开头就给它赋值，
    // 而 `PairingStore.save` 是异步的（第一版就在这里竞态 —— `captured` 有值、
    // 存储里还没有，于是后面每一步都建不起连）。
    final landed = await _waitFor(
      tester,
      () async => (await PairingStore.load()) != null,
    );
    expect(landed, isTrue, reason: '凭据必须真的落进安全存储（flutter_secure_storage）');
    final credentials = await PairingStore.load();
    expect(credentials, isNotNull, reason: '凭据必须真的落进安全存储');

    // ---- 第二段：用真凭据装配真 AppModel 并建连 ----
    //
    // 这里**照抄** `main.dart` 的装配（集成测试刻意不 import 私有函数：
    // 要验的是"这条链在设备上通"，不是"装配点没写错"）。
    final store = SqfliteItemStore();
    await store.open();
    final identity = await deriveIdentity(credentials!.masterSeedHex);
    final staticKeys = await x25519FromSeed(identity.dhSeedHex);
    final deviceId = await credentials.helloDeviceId();
    final pairingClient = PairingClient(
      relayUrl: credentials.relayUrl,
      send: createHttpSender(),
      // 与装配点同一个判据（见 `main.dart` 的 `_assemble` 与
      // `assembly_invariants_test.dart` 钉住的那条）。
      allowInsecureLocal: true,
    );
    // **带记录的传输**：2026-10-13 真机排查用。`core/_write` 把 `send()` 的返回值
    // 丢掉了（帧封箱之后才交出去），而"socket 没收下这一帧"与"发成功了"在诊断面上
    // 长得一模一样。包一层把每次 send 的返回值记下来，失败时就能分开
    // "帧没出手机"与"帧死在路上"。
    final recorder = _RecordingTransport(
      TicketedWebSocketTransport(
        endpoint: credentials.relayUrl,
        ticket: () async => (await pairingClient.ticketByDeviceToken(
          credentials.deviceToken,
        )).ticket,
      ),
    );
    final client = createSyncClient(
      SyncClientDeps(
        transport: recorder,
        handshake: createHandshakeDriver(
          identity: HandshakeIdentity(
            staticKeys: staticKeys,
            signSeedHex: identity.signSeedHex,
            devId: deviceId,
          ),
          peer: PeerIdentity(
            pcSignPubHex: credentials.pcSignPubHex,
            pcDhPubHex: credentials.pcDhPubHex,
            pcId: credentials.pcId,
            pairingId: credentials.pairingId,
          ),
          newEphemeralSeedHex: () => toHex(randomBytes(32)),
          newNonceHex: () => toHex(randomBytes(32)),
          newFrameIdHex: () => newFrameId(randomBytes(frameIdBytes)),
        ),
        box: (keys) => BoxCodec(keys: keys, role: HandshakeRole.initiator),
        outbox: Outbox(store: SqfliteOutboxStore(store)),
        session: DeviceSession(),
        persistence: StoreItemPersister(store),
      ),
    );
    final app = AppModel(client: client);
    addTearDown(() async {
      app.dispose();
      await client.close();
      await store.close();
      await PairingStore.clear();
    });

    await app.start();
    final serving = await _waitFor(
      tester,
      () async => app.connection == ConnectionStateView.serving,
    );
    expect(
      serving,
      isTrue,
      reason: '建连 + 握手必须通；连接诊断：${app.connectionDiagnosis ?? '无'}',
    );

    // ---- ① sync.hello：前后台态 + 订阅集 ----
    //
    // 这是整条链的地基：没有它，电脑侧 `liveDevices()` 恒为空，
    // `decideTakeover` 永不 claim，审批转手机**永远不触发**。
    final probe = client is SyncClientProbe ? client as SyncClientProbe : null;
    expect(probe, isNotNull, reason: '诊断面必须拿得到（装配给了真实现）');
    final hello = probe!.sentRequests
        .where((e) => e['method'] == 'sync.hello')
        .toList();
    expect(hello, isNotEmpty, reason: '进服务态必须声明一次 sync.hello');
    expect(hello.last['params'], {
      'app': 'foreground',
      'sessions': <Object?>[],
    }, reason: '前后台态如实报；此刻还没订阅任何会话');
    // 声明之后连接必须还在（真机上曾在这里掉线，所以显式钉一句）。
    expect(
      app.connection,
      ConnectionStateView.serving,
      reason: '发过 sync.hello 之后不该掉线；诊断：${app.connectionDiagnosis ?? '无'}',
    );

    // ---- ② session.list：遥控电脑看会话 ----
    await app.refreshSessions();
    expect(
      app.lastError,
      isNull,
      reason:
          '拉会话列表不该失败；连接诊断：${app.connectionDiagnosis ?? '无'}；'
          '连接态：${app.connection}',
    );
    expect(app.sessions, isNotEmpty, reason: '电脑上有会话（这台 profile 有 250+ 个）');
    // **不能挑"最新那个"**：`session.list` 按最近活动排序，最新那条往往正是**另一个人
    // 正在跑的会话**，把探针塞进去会排队进它的下一个轮次，等于用它当靶子
    //（实测：上一轮就这么把标记投进了另一个 agent 的会话，把它叫醒）。
    // 判据与步骤 ⑤ 相同：只往**空闲**会话里发；清单要**重新拉**，步骤 ② 那份的
    // `running` 已经过期。
    await app.refreshSessions();
    // **只给审批靶子留一个会话**（步骤 ⑤ 用的那个），其余全留给标记探针。
    //
    // 两步都**优先落在专用工作区**里：那条工作区是用户专门给联调建的，
    // 而满清单里 250+ 条会话属于他的其他项目 —— 探针投进去会消耗他的真实会话，
    // 还可能撞上一条用着付费渠道的会话（成本纪律）。
    // 只留一个是必须的：整批留光的话标记探针就只剩用户的会话可用了。
    final targetOrdered =
        app.sessions.where((s) => !s.running && _isTargetWorkspace(s)).toList()
          ..sort(_compareTargets);
    final reservedId = targetOrdered.isEmpty ? null : targetOrdered.first.sid;
    final markerPool = app.sessions.where((s) => s.sid != reservedId).toList()
      // 同一套排序：专用工作区优先，其次从没被 agent 跑过。
      ..sort(_compareTargets);
    // **优先挑"从没被 agent 跑过"的空会话**（`blank`），挑不到再退到任意空闲。
    //
    // 为什么不能只按 `!running` 挑：最新那条"空闲"往往是**刚被别的 agent
    // 跑完一轮**的会话，把探针投进去会把那个 agent 唤醒（2026-10-13 真机两次
    // 都踩到：一次投进另一个 agent 的会话、一次投进一个刚建的空会话）。
    // `blank` 是电脑侧的原话（`connector/src/dsh/sessions.ts`：还没有任何轮次）。
    // 上面已经按"专用工作区优先、blank 优先"排过序，所以取第一个空闲的就是它。
    final idle = markerPool.where((s) => !s.running).toList();
    expect(
      idle,
      isNotEmpty,
      reason:
          '至少要有空闲会话可当探针目标（否则这一步没法验）；'
          '总会话数：${app.sessions.length}，其中专用工作区：'
          '${app.sessions.where(_isTargetWorkspace).length}',
    );
    final sid = idle.first.sid;
    expect(
      sid,
      matches(RegExp(r'^[A-Za-z0-9_-]+$')),
      reason: 'sid 要过 AAD 的字符集',
    );

    // ---- ③ 点开会话：订阅 → ev 流进来 ----
    final firstEvent = Completer<void>();
    final sub = client.sessionUpdates(sid).listen((delta) {
      if (delta.events.isNotEmpty && !firstEvent.isCompleted) {
        firstEvent.complete();
      }
    });
    await app.openSession(sid);
    final gotEvent = await _waitFor(tester, () async => firstEvent.isCompleted);
    expect(gotEvent, isTrue, reason: '订阅之后必须有 ev 进来（否则手机上永远看不到内容）');
    expect(
      probe.declaredSessions.containsKey(sid),
      isTrue,
      reason: '订阅集要记下来，重连后由 sync.hello 整份重新声明',
    );

    // ---- ④ 发一句：电脑侧必须受理 ----
    //
    // **不能断言 `call` 的返回值**：`session.prompt` 带幂等键，而 `SyncClient.call`
    // 对带键的写操作**按设计返回 null**（"队列发出去了，但结果要等 `res`；
    // 不建在途等待，结果由会话流收敛"）。所以判据取两头：
    // ① 帧真的发出去了（诊断面上的明文信封）；
    // ② 电脑侧把它当成一条 `user/message` 落进了会话 —— 那条 `ev` 会回到手机。
    final marker = 'dsh-mobile 真机联调 ${DateTime.now().microsecondsSinceEpoch}';
    final echoed = Completer<void>();
    final echoSub = client.sessionUpdates(sid).listen((delta) {
      for (final event in delta.events) {
        if (jsonEncode(event.data).contains(marker) && !echoed.isCompleted) {
          echoed.complete();
        }
      }
    });
    await client.call<Object?>(
      'session.prompt',
      <String, Object?>{
        'sid': sid,
        'content': [
          {'type': 'text', 'text': marker},
        ],
      },
      requestId: 'real-device-${DateTime.now().microsecondsSinceEpoch}',
    );

    final sent = probe.sentRequests
        .where((e) => e['method'] == 'session.prompt')
        .toList();
    expect(sent, isNotEmpty, reason: 'session.prompt 必须真的发出去（带幂等键的信封）');
    expect(sent.last['requestId'], isNotEmpty, reason: '写操作必须带幂等键（§5.6）');

    // **窗口按"电脑侧跑完一整个模型回合"给，不用默认 30 秒**：
    // `session.prompt` 走 `agent.followup`
    // （`packages/api/session-controller/src/commands.ts` 的 prompt 分支，`:365`），
    // 而 followup 插的是 `next-turn`
    // （`packages/core/agent-loop/src/agent.ts:163` 的 `followup → send(…, 'next-turn', …)`）——
    // 会话正在跑轮次时，这条 `user/message` 要等**当前轮次结束**才落盘。
    // 步骤 ② 挑空闲会话只是降低撞上在跑轮次的概率（清单拉到发探针之间仍可能起轮次），
    // 不是保证；免费渠道一个轮次轻易超过 30 秒。
    // **判据不变**：电脑侧确实受理了（那句话作为 `user/message` 回到手机），
    // 不等模型回什么。
    final gotEcho = await _waitForModel(tester, () async => echoed.isCompleted);
    if (!gotEcho) {
      _dumpDiagnostics('回读失败', sid, app, probe, recorder);
    }
    expect(gotEcho, isTrue, reason: '发出去的那句必须作为 user/message 回到手机（否则电脑侧没受理）');
    await echoSub.cancel();
    await sub.cancel();

    // ---- ⑤ 审批转手机：电脑侧等审批 → 手机开卡 → 「允许一次」→ interaction.respond ----
    //
    // 这一步才是"能遥控电脑"：前面几步只证明手机**看得见**电脑，
    // 这一步证明手机**能替桌面做决定**。
    //
    // 三处刻意的选择：
    // ① **必须挑一个没有未决审批的会话**。`flutter test integration_test` 会先卸载再装
    //    测试包 ⇒ 手机 sqflite 被清 ⇒ `since = 0` ⇒ 连接器把**整段历史**重放给手机。
    //    历史会话里只要留着一条没答的 `approval/asked`（上一轮跑留下的），手机就会先看到
    //    **那条作废的审批**并去答它 —— 而连接器只为**本次**这条建有在途 claim，于是答复
    //    落空、卡片被标成"已过期"，本次的审批永远等不到回答。
    //    实测踩过：一个会话里两条 `approval/asked`（相隔 10 分钟）、`decided = 0`。
    //    所以这里逐个候选挑干净的，挑不到就明说，不猜。
    // ② **触发方式必须真的越权**：`workspace-write` 档下只读命令不会弹审批，
    //    所以那句提示词要写工作区之外的文件（`C:/Windows/Temp`）。
    // ③ **候选必须此刻空闲，而且不能是本轮那条标记探针所在的会话**。
    //    给一个正在跑的会话发消息，DSH 会把它**排到下一个轮次**
    //    （`sessionController.prompt` 走 `agent.followup`，`commands.ts:365`），
    //    而这里的等待窗口只有 3 分钟 —— 实测踩过：审批探针被排到它自己那条标记探针
    //    的 turn 后面，`approval/asked` 一直不出现，卡永远等不到。
    //    空闲判据取电脑侧给的 `running`（`session.list` 一直在发它）：
    //    **必须重新拉一次清单**，步骤 ② 那份是发标记之前拉的，`running` 已经过期。
    // ④ **候选里 `blank`（从没被 agent 跑过）的排前面**，理由同步骤 ②：
    //    只按 `!running` 挑会挑到刚被别人跑完一轮的会话，把探针投进去会把
    //    那个 agent 唤醒（2026-10-13 真机两次都踩到）。
    //    步骤 ② 预留的那个排在首位，其余同工作区会话是备胎。
    await app.refreshSessions();
    expect(app.lastError, isNull, reason: '挑审批目标前要重新拉清单；失败：${app.lastError}');
    // **靶子钉在专用工作区**，而且是**步骤 ② 预留的那一个**：
    //
    // ① **工作区**：满清单里绝大多数会话属于用户的其他项目。探针投进去
    //    消耗他的真实会话（成本纪律），也可能撞上工作区已失效的会话 ——
    //    那种会话 `session.prompt` 照常落 `user/message`（所以④的回读判据
    //    照样满足），而 agent 永远不起轮次，`approval/asked` 永远不来。
    // ② **渠道**：会话存着自己的模型选择，不是当前 profile 配的渠道就起不来。
    //    但新会话的投影给不出值（见 `_targetRank`），所以这里只排序不过滤。
    //
    // **还有一条这里查不到、必须在电脑侧先准备好的：权限档。**
    // `approval/policy: never`（`danger-full-access` 预设带的）下审批
    // **根本不问**，探针直接跑成功，手机上永远没有卡 —— 2026-10-13 第三次
    // 真机"探针落盘了但卡片没出现"就是这个原因。而**这个 profile 新建会话的
    // 默认访问模式就是「完全权限」**，所以每一次都要先切。跑之前先在靶子会话的
    // 访问模式菜单里选「工作区内修改」（等价于 `/permission workspace-write`），
    // 然后按帧解压它的会话日志，确认 `permission/preset` / `sandbox/mode` /
    // `approval/policy` 三个字端真的换成 `workspace-write` / `ask`。
    // Note: 为什么是权限档而不是别的 —— 见
    // `.agents/notes/implemented/2026-10-14-approval-probe-needs-ask-policy.md`
    final pool =
        app.sessions
            .where((s) => s.sid != sid && !s.running && _isTargetWorkspace(s))
            .toList()
          ..sort(_compareTargets);
    final candidates = pool.map((s) => s.sid).toList();
    String? approvalSid;
    for (final candidate in candidates.take(8)) {
      await app.openSession(candidate);
      final quiet = await _waitForQuiet(tester, () => app.items.length);
      final dirty = app.items.any((i) => i is ApprovalItem && !i.decided);
      if (quiet && !dirty) {
        approvalSid = candidate;
        break;
      }
    }
    expect(
      approvalSid,
      isA<String>(),
      reason:
          '挑不到「空闲 + 干净 + 专用工作区 + 不是本轮探针」的会话：'
          '空闲是必须的（给在跑的会话发消息会被排到下一个轮次，等不到 approval/asked），'
          '干净是必须的（历史里作废的审批会被手机先看到），'
          '专用工作区是必须的（否则靶子是用户的其他会话）。'
          '要求 cwd=$_targetCwd，渠道优先 $_targetProvider；'
          '总会话数：${app.sessions.length}，其中空闲：'
          '${app.sessions.where((s) => !s.running).length}，'
          '工作区匹配：${app.sessions.where(_isTargetWorkspace).length}',
    );
    // 上面已断言非空，这里收窄成非空（Dart 的类型提升认不出 `expect` 的断言）。
    final targetSid = approvalSid!;
    const runMarker = 'dsh-probe-ok';
    final opened = Completer<InteractionItem>();
    final settled = Completer<String>();
    final ranCommand = Completer<void>();
    final interactionSub = app.interactions.listen((signal) {
      switch (signal) {
        case InteractionOpened(:final item):
          if (item.kind == InteractionKind.approval && !opened.isCompleted) {
            opened.complete(item);
          }
        case InteractionSettled(:final itemId):
          if (!settled.isCompleted) settled.complete(itemId);
      }
    });
    final resultSub = client.sessionUpdates(targetSid).listen((delta) {
      for (final event in delta.events) {
        // **只认 `tool/result`**：`tool/call` 里也带着命令原文（含标记），
        // 拿它当判据是恒真式 —— 命令发出去就有了，跑没跑过完全看不出来。
        if (event.type == 'tool/result' &&
            jsonEncode(event.data).contains(runMarker) &&
            !ranCommand.isCompleted) {
          ranCommand.complete();
        }
      }
    });

    // 真 UI：接管卡挂在 ChatPage 上（与装配点同一处，`chat_page.dart:154`）。
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: true,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await app.openSession(targetSid);
    final subscribed = await _waitFor(
      tester,
      () async => probe.declaredSessions.containsKey(targetSid),
    );
    expect(subscribed, isTrue, reason: '接管要求"前台 + 订阅了这个会话"，所以先订阅');

    await client.call<Object?>(
      'session.prompt',
      <String, Object?>{
        'sid': targetSid,
        'content': [
          {
            'type': 'text',
            'text':
                '请立刻用你的命令行工具（pwsh / Bash 都行）执行这一条命令,'
                '不要改成别的命令,也不要先问我：'
                '`Set-Content -Path C:/Windows/Temp/dsh-probe.txt -Value $runMarker; '
                'Get-Content C:/Windows/Temp/dsh-probe.txt`。'
                '它要写工作区之外的文件,按当前权限档需要审批。',
          },
        ],
      },
      requestId:
          'real-device-approval-${DateTime.now().microsecondsSinceEpoch}',
    );

    // **先等探针自己作为 `user/message` 落回来**（与步骤 ④ 同一个判据），
    // 再等卡片。理由：`session.prompt` 是"发了不等结果"的幂等写，被拒时
    // （例如挑到的会话 agent 已 disposed → `session/not-found`）手机上**没有任何
    // 信号**，而连接器会把 pending 行删掉、不留痕迹。跳过这一步直接等卡片，
    // "prompt 没被受理"与"模型没调工具"会一起表现成"等了 3 分钟没有卡"，
    // 分不开（2026-10-13 真机就这么白跑过两轮）。
    final probeEcho = Completer<void>();
    final probeEchoSub = client.sessionUpdates(targetSid).listen((delta) {
      for (final event in delta.events) {
        if (jsonEncode(event.data).contains('dsh-probe.txt') &&
            !probeEcho.isCompleted) {
          probeEcho.complete();
        }
      }
    });
    final probeEchoed = await _waitForModel(
      tester,
      () async => probeEcho.isCompleted,
    );
    if (!probeEchoed) _dumpDiagnostics('审批探针没有落回来', sid, app, probe, recorder);
    expect(
      probeEchoed,
      isTrue,
      reason: '审批探针必须被电脑侧受理（作为 user/message 落回来），否则卡片永远等不到',
    );
    await probeEchoSub.cancel();

    final gotCard = await _waitForModel(
      tester,
      () async => opened.isCompleted || find.text('等待审批').evaluate().isNotEmpty,
    );
    if (!gotCard) _dumpDiagnostics('探针已受理但审批卡没出现', sid, app, probe, recorder);
    expect(
      gotCard,
      isTrue,
      reason:
          '电脑侧等审批时手机上必须开卡（否则就是"电脑在等、手机什么都没有"）；'
          '连接诊断：${app.connectionDiagnosis ?? '无'}',
    );
    final item = await opened.future;
    expect(item.callId, isNotEmpty, reason: '没有 callId 就没法从手机答（§6.3）');
    expect(
      find.text('等待审批').evaluate(),
      isNotEmpty,
      reason: '卡片要真的画在输入栏上,不只是信号到了',
    );

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();

    final respondCalls = probe.sentRequests
        .where((e) => e['method'] == 'interaction.respond')
        .toList();
    expect(
      respondCalls,
      isNotEmpty,
      reason: '点「允许一次」必须真的发出 interaction.respond',
    );
    final params = respondCalls.last['params']! as Map<String, Object?>;
    expect(
      params['callId'],
      item.callId,
      reason: '答复要带电脑侧那个 callId,否则电脑侧认不出在答哪一项',
    );
    expect(
      respondCalls.last['requestId'],
      'i:${item.callId}',
      reason: '幂等键是 i:<callId>（§5.7）—— 重复点两次不该变成两次授权',
    );
    // 钉**字面值**：import 同一个常量会让"把契约字符串改坏"在实现与判据两边一起变绿
    //（本项目踩过一次恒真式，见 `.agents/notes/` 那篇笔记的 Consequences）。
    expect(
      jsonEncode(params['answers']),
      contains('"allowed-once"'),
      reason: '「允许一次」的线上编码是 allowed-once（跨端契约,连接器侧有同名常量）',
    );

    final gotSettled = await _waitForModel(
      tester,
      () async => settled.isCompleted,
    );
    expect(gotSettled, isTrue, reason: '答完之后那一项必须收束（否则卡片永远挂在输入栏上）');
    final gotRun = await _waitForModel(
      tester,
      () async => ranCommand.isCompleted,
    );
    expect(
      gotRun,
      isTrue,
      reason:
          '审批通过后电脑侧必须真的继续 —— 那条命令要跑出 $runMarker 的结果；'
          '只看到卡消失、没有结果事件,说明"答了但没落地"',
    );

    await resultSub.cancel();
    await interactionSub.cancel();
  });
}
