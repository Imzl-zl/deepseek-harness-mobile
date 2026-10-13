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
///   --dart-define=DSH_QR_PAYLOAD_B64=$b64
/// ```
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

String get _qrPayload {
  if (_qrPayloadB64.isEmpty) return '';
  return utf8.decode(base64.decode(_qrPayloadB64));
}

ChannelTransport _pairingTransport(String upgradeUrl) =>
    WebSocketTransport(WebSocketTransportOptions(url: upgradeUrl));

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
    final client = createSyncClient(
      SyncClientDeps(
        transport: TicketedWebSocketTransport(
          endpoint: credentials.relayUrl,
          ticket: () async => (await pairingClient.ticketByDeviceToken(
            credentials.deviceToken,
          )).ticket,
        ),
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
    final idle = app.sessions.where((s) => !s.running).toList();
    expect(idle, isNotEmpty, reason: '至少要有空闲会话可当探针目标（否则这一步没法验）');
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

    final gotEcho = await _waitFor(tester, () async => echoed.isCompleted);
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
    await app.refreshSessions();
    expect(app.lastError, isNull, reason: '挑审批目标前要重新拉清单；失败：${app.lastError}');
    String? approvalSid;
    for (final candidate
        in app.sessions
            .where((s) => s.sid != sid && !s.running)
            .take(8)
            .map((s) => s.sid)) {
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
          '挑不到「空闲 + 干净 + 不是本轮探针」的会话：空闲是必须的（给在跑的会话'
          '发消息会被排到下一个轮次，等不到 approval/asked），干净是必须的'
          '（历史里作废的审批会被手机先看到），不是本轮探针也是必须的'
          '（那条标记探针刚把它的轮次跑起来）；候选数：${app.sessions.length}',
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

    final gotCard = await _waitForModel(
      tester,
      () async => opened.isCompleted || find.text('等待审批').evaluate().isNotEmpty,
    );
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
