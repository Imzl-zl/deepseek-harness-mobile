/// **真机端到端**：点「新建会话」之后，页面必须真的换成新会话。
///
/// ## 为什么这条必须跑在设备上
///
/// 2026-11-10 用户反馈「新建会话感觉没用 —— 点击了还是旧会话页面」。
/// 这条链的判据横跨三层，而**只有一整条真链能同时满足**：
///
/// ```text
/// 真 App 装配（main.dart）→ 点顶栏 ＋ → _newSession()
///   → findBlankSession / session.create（真电脑侧）
///   → openSession(新 sid) → ChatPage 重建 → 顶栏标题与正文真的换了
/// ```
///
/// widget 测试能覆盖 `AppModel` 的两半，却**碰不到 `main.dart` 里那个 `_newSession`**
/// （它是私有方法，测试只能抄一份 —— 抄一份就变成"测试复述实现"，它红不了）。
/// 所以这里直接 `main()` 起真 App，再点真按钮。
///
/// ## 它验什么
///
/// 电脑侧现有数据决定落点，两种都会出现，两种都要能跑：
///
/// 1. **电脑侧没有 blank**（落点是**有内容的旧会话**）：点 ＋ 必须让顶栏标题变成
///    「新建会话」并画出 hero —— 这是用户看见的那一屏；
/// 2. **电脑侧有 leftover blank**（落点就是那个 blank）：那一次 ＋ 照 DSH 的
///    reuse-or-create 是**复用当前这个**，页面本就不变（不多建、不切走）。
///
/// 两种落点下，**再点一次 ＋ 都不能多建**（标题仍是「新建会话」）。
/// 电脑侧的证据（`session.list` 只多一行）在跑完后的脚本里对。
///
/// 最后一段还会在会话里**真发一句**（隔离实例没配模型密钥，这一轮会以
/// `Connection error` 失败，不花钱），再点 ＋ —— 判据是那一句从页面消失
/// （新会话没有条目）。它盯的是「刚聊过的会话不是新会话」这条不变量。
///
/// ## 跑法（电脑侧要有一台隔离实例，见 `tools.md` 的「隔离实例」一节）
///
/// ```powershell
/// # 1. 电脑侧：出码 → 解出载荷 JSON（`D:\tmp\decode-pair.mjs`）
/// # 2. 手机必须能直连那台实例（载荷里的 lan 地址）
/// adb shell 'curl -m 5 -sS -o /dev/null -w "%{http_code}" http://<pc>:<port>/'   # 426 = 通
/// $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
/// cd app
/// flutter test integration_test/new_session_real_device_test.dart -d d61cf622 `
///   --dart-define=DSH_QR_PAYLOAD_B64=$b64
/// ```
///
/// **跑完 App 会被卸掉**（`flutter test integration_test` 的行为，见 `tools.md`）——
/// 跑完要 `flutter build apk --debug` + `adb install -r` 装回来。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/main.dart' as mobile;
import 'package:dsh_mobile/platform/http_sender.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/conversation_hero.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _payloadB64 = String.fromEnvironment('DSH_QR_PAYLOAD_B64');

String get _payload =>
    _payloadB64.isEmpty ? '' : utf8.decode(base64.decode(_payloadB64));

/// 电脑侧的**直连**监听面（裸 WS，无票无路径）。
///
/// 为什么要在测试里手工塞进去：直连端点本来是"经中转连上之后由
/// `endpoint.describe` 学到"的（`connector/src/endpoints.ts`），而这条用例**不想**
/// 为了一个端点表再造一台中转出来。塞进去的是**真地址**、之后走的也是真链路
/// （真握手 → 真 `sync.hello` → 真 `session.list` / `session.create`），
/// 只是省掉"先经中转学一遍"那一步。
const _directUrl = String.fromEnvironment('DSH_DIRECT_URL');

Endpoint get _directEndpoint =>
    const Endpoint(kind: EndpointKind.direct, url: _directUrl, manual: true);

ChannelTransport _pairingTransport(String upgradeUrl) =>
    WebSocketTransport(WebSocketTransportOptions(url: upgradeUrl));

/// 真网络 + `pump` 交替地等一个条件成立（真网络期间页面一直在变，
/// 单用 `pumpAndSettle` 会一直等不到"没有待处理的帧"）。
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

/// 顶栏里的标题文案（同一行还有计数 chip，所以要按"是不是那一行"取）。
String _appBarText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: find.byType(ChatAppBar), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .join(' | ');

/// 页面上所有 Text 的文案（失败时打出来，省得再跑一轮）。
String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .join(' | ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机：旧会话上点「新建会话」必须真的换到新会话，且连点只建一个', (tester) async {
    if (_payload.isEmpty) {
      markTestSkipped('未提供 DSH_QR_PAYLOAD_B64：这条用例需要一台在跑的隔离实例');
      return;
    }

    // ---- 第一段：清掉旧凭据，走完整两段配对（凭据留给真 App 用）----
    await pairingStore.clear();
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
            await pairingStore.save(
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

    await tester.enterText(find.byType(TextField), _payload);
    await tester.tap(find.text('连接电脑'));
    final ready = await _waitFor(
      tester,
      () async => find.text('通道已就绪，等待你确认').evaluate().isNotEmpty,
    );
    expect(ready, isTrue, reason: '受限通道应建起来；页面文案：${_allText(tester)}');

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并配对'));
    final paired = await _waitFor(
      tester,
      () async => find.text('配对成功').evaluate().isNotEmpty,
    );
    expect(paired, isTrue, reason: '提交后应拿到回执；页面文案：${_allText(tester)}');

    await tester.ensureVisible(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    final landed = await _waitFor(
      tester,
      () async => (await pairingStore.load()) != null,
    );
    expect(landed, isTrue, reason: '凭据必须真的落进安全存储');
    expect(captured, isNotNull);

    // ---- 第一段半：给这台电脑塞一条**直连**端点（见 [_directUrl] 的注释）----
    expect(_directUrl, isNotEmpty, reason: '必须给 DSH_DIRECT_URL（电脑侧直连监听面）');
    final credentials = await pairingStore.load();
    await pairingStore.saveEndpoints(
      hostId: credentials!.pcSignPubHex,
      endpoints: [_directEndpoint],
    );

    // ---- 第二段：起**真 App**（`main.dart`），它会用这份凭据装配并建连 ----
    mobile.main();

    // 等落点：真 App 起得来（顶栏在）。落点是谁由电脑侧现有数据决定 —— 有 leftover
    // blank 时会落在 blank 上（标题就是「新建会话」），没有时落在有内容的旧会话上。
    final up = await _waitFor(
      tester,
      () async => find.byType(ChatAppBar).evaluate().isNotEmpty,
      rounds: 600,
      stepMs: 200,
    );
    expect(up, isTrue, reason: '真 App 必须起来（顶栏在）');
    // 再多给一秒让落点那一路的快照回来（标题与条目分两拍）。
    await _waitFor(
      tester,
      () async => find.byType(ChatAppBar).evaluate().isNotEmpty,
      rounds: 10,
    );
    final titleBefore = _appBarText(tester);
    final startedOnBlank = find
        .descendant(of: find.byType(ChatAppBar), matching: find.text('新建会话'))
        .evaluate()
        .isNotEmpty;
    debugPrint(
      '[new-session] 落点：${startedOnBlank ? '电脑侧已有的 blank（页面已在新会话上）' : '有内容的旧会话'}'
      '；点击前顶栏：$titleBefore',
    );

    // ---- 第三段：点顶栏 ＋（这就是用户那一下）----
    // **两种落点都要能跑**：电脑侧有 leftover blank 时落点会落在 blank 上，那一次 ＋
    // 照 DSH 的 reuse-or-create 正是**复用当前这个**、页面本就不变（写在下面的
    // 第四段）。把它当失败会让用例只在"电脑侧没有 blank"时才绿，而真机上两种都会出现。
    final plus = find.descendant(
      of: find.byType(ChatAppBar),
      matching: find.byTooltip('新建会话'),
    );
    expect(plus, findsOneWidget, reason: '顶栏 ＋ 必须在');
    await tester.tap(plus);
    await tester.pump();

    // 判据：标题变成「新建会话」，正文画出 hero。
    final switched = await _waitFor(
      tester,
      () async =>
          find
              .descendant(
                of: find.byType(ChatAppBar),
                matching: find.text('新建会话'),
              )
              .evaluate()
              .isNotEmpty &&
          find.text(kHeroHeadline).evaluate().isNotEmpty,
      rounds: 300,
      stepMs: 200,
    );
    debugPrint('[new-session] 点击后顶栏：${_appBarText(tester)}');
    expect(
      switched,
      isTrue,
      reason:
          '点「新建会话」之后必须换到新会话（标题「新建会话」+ hero）。'
          '实际顶栏：${_appBarText(tester)}；页面文案：${_allText(tester)}',
    );

    // ---- 第四段：再点一次 ⇒ 复用刚建的那个 blank，不多建 ----
    await tester.tap(plus);
    await tester.pump();
    await _waitFor(tester, () async => false, rounds: 10);
    expect(
      find
          .descendant(of: find.byType(ChatAppBar), matching: find.text('新建会话'))
          .evaluate()
          .isNotEmpty,
      isTrue,
      reason: '第二次点击该复用，不该把页面切走；顶栏：${_appBarText(tester)}',
    );

    // ---- 第五段：**这一句才是「点了没用」那一步** ----
    //
    // 在刚建出来的新会话里发一句（宿主落 `user/message` + `turn/start`），然后立刻
    // 再点 ＋。判据：**那一句从页面上消失** —— 说明真的换到了一个没有条目的新会话。
    //
    // 不花钱：隔离实例没有配模型密钥，这一轮的模型调用会当场失败；
    // 而 `turn/start` 在调模型**之前**就已经落了（DSH 的 `list.ts:51` 也是据此翻 blank）。
    final composer = find.descendant(
      of: find.byType(DshComposer),
      matching: find.byType(TextField),
    );
    expect(composer, findsOneWidget, reason: '输入栏必须在');
    await tester.enterText(composer, _probeText);
    await tester.pump();
    debugPrint('[new-session] 输入后页面：${_allText(tester)}');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await _waitFor(tester, () async => false, rounds: 5, stepMs: 200);
    debugPrint(
      '[new-session] 发送后页面：${_allText(tester)}'
      ' | probe 节点数=${find.text(_probeText).evaluate().length}',
    );
    final sent = await _waitFor(
      tester,
      () async => find.text(_probeText).evaluate().isNotEmpty,
      rounds: 100,
      stepMs: 200,
    );
    debugPrint('[new-session] 发完一句，顶栏：${_appBarText(tester)}');
    expect(sent, isTrue, reason: '自己发的那一句必须出现在会话里；页面文案：${_allText(tester)}');
    // 等 `turn/start` 到手机（宿主开轮次 → 下行 delta）。这 6 秒是本用例的**被测窗口**。
    await _waitFor(tester, () async => false, rounds: 30, stepMs: 200);

    await tester.tap(plus);
    await tester.pump();
    final gone = await _waitFor(
      tester,
      () async => find.text(_probeText).evaluate().isEmpty,
      rounds: 100,
      stepMs: 200,
    );
    debugPrint('[new-session] 发过一句之后点 ＋，顶栏：${_appBarText(tester)}');
    expect(
      gone,
      isTrue,
      reason:
          '刚发过一句的会话已经不是 blank，再点 ＋ 必须换到**新**会话（那一句应该消失）。'
          '它还在 = 复用判据把当前会话当成了新会话。'
          '页面文案：${_allText(tester)}',
    );

    // 收尾：凭据留着无妨（下一次跑会先清），但设备安全存储里不该留一份
    // 指向已关掉的隔离实例的凭据 —— 清掉。
    await pairingStore.clear();
  });
}

/// 第五段发出去的那一句（纯 ASCII：这台设备的 IME 吃不下中文）。
const String _probeText = 'probe-blank-row';
