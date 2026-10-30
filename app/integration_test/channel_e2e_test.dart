/// **真机端到端**：粘贴真二维码 → 配对（两段）→ 连上中转 → 发一句 → 收一句。
///
/// ## 这是本次交付的验收判据在设备上的那一半
///
/// `connector/tests/pairing-e2e.test.ts` 证明了**协议链**在真 HTTP + 真 WS 上成立
/// （用 TS 写的手机替身）。这一条证明**Dart 侧的实现**能跟同一套电脑侧装配对上 ——
/// 也就是两套独立实现之间的互操作。两者缺一不可：
/// 替身全绿而 Dart 侧没接上，真机上就是"连不上"。
///
/// ## 配对是两段（v2），所以这里有两次点击
///
/// ```text
/// 点「连接电脑」  → 换票(候选) → 升级 → 受限握手   ← 秘密还没出去
/// 点「确认并配对」→ pair-commit（密文里是配对码）→ pair-result（设备令牌）
/// 点「完成」      → 落盘并建连
/// ```
///
/// 中间那一步是**人**的决定（`pairing-v2.md` §5）：确认之前电脑侧连这台设备的记录
/// 都没有。用例必须真的点它 —— 少了它，`onPaired` 永远不回调，而看起来像"配对没成功"。
///
/// ## 跑法
///
/// ```powershell
/// adb reverse tcp:8787 tcp:8787
/// adb shell svc power stayon true      # 屏幕灭掉 = 引擎暂停 = 用例永远跑不完
/// $qr = '<出码命令给的那段 JSON>'
/// $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($qr))
/// cd app
/// flutter test integration_test/channel_e2e_test.dart -d d61cf622 `
///   --dart-define=DSH_QR_PAYLOAD_B64=$b64
/// ```
///
/// 载荷走 **base64**：它是满是双引号的 JSON，直接放进 `--dart-define` 会被
/// PowerShell 的引号解析吃掉，于是 App 收到 `{v:2,…}` 并报"二维码不是合法 JSON"
/// —— 那是输入坏，不是实现坏，但看起来一模一样（实测踩过）。
///
/// **不给就跳过**（而不是失败）：这条用例的前置是一整套在跑的服务，
/// 而"前置没起"与"实现不对"是两件事 —— 混在一起会让门禁永远红着。
///
/// ## 两个只在真机上才会遇到的前置（实测踩过）
///
/// 1. **屏幕必须亮着**：屏幕灭掉时 Flutter 引擎被暂停，用例会一直挂在
///    "did not complete"且**没有原因**。`svc power stayon true` 是必须的。
/// 2. **明文 HTTP 要在 debug 构建里放行**：Android 9 起默认禁止明文，
///    而本机中转是 `http://127.0.0.1:8787` —— 那个请求会在应用层被拒，
///    中转侧**一条日志都没有**。放行范围见
///    `android/app/src/debug/res/xml/network_security_config.xml`；
///    Dart 侧的对应开关是 `PairingPage.allowInsecureLocal`（本用例显式打开）。
///
/// ## 为什么用真机而不是模拟器
///
/// 本机模拟器反复崩（见 `AGENTS.md`）；而这条用例要的是
/// "真 Keystore + 真 socket + 真中转"，模拟器一样都不多给。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/platform/http_sender.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 电脑侧出码命令给出的那段字符串（见文件头的跑法），**base64 编码**。
///
/// 为什么要编码：那段载荷是一串**满是双引号**的 JSON，而 `--dart-define` 的值要穿过
/// PowerShell 的引号解析 —— 实测它会把引号吃掉，于是 App 收到的是
/// `{v:2,relay:ws://…}`，报"二维码不是合法 JSON"（而那是**输入坏**，不是实现坏）。
/// base64 只有 `[A-Za-z0-9+/=]`，任何 shell 都不会动它。
const _qrPayloadB64 = String.fromEnvironment('DSH_QR_PAYLOAD_B64');

/// 解出真正的载荷；没给就返回空串（用例据此跳过）。
String get _qrPayload {
  if (_qrPayloadB64.isEmpty) return '';
  return utf8.decode(base64.decode(_qrPayloadB64));
}

/// 一条**真的**传输：给一条已带票的 URL 建 WebSocket（与装配点同形）。
///
/// 这里刻意重写一份而不是 import `main.dart` 里的私有函数：
/// 集成测试要验的是"这条链在设备上通"，而不是"装配点没写错"。
ChannelTransport _pairingTransport(String upgradeUrl) =>
    WebSocketTransport(WebSocketTransportOptions(url: upgradeUrl));

/// 等页面出现某段文案（真网络 + `pump` 交替，理由见下面的循环注释）。
Future<bool> _waitForText(WidgetTester tester, String text) async {
  for (var i = 0; i < 200; i += 1) {
    // **必须 `runAsync` 与 `pump` 交替**，两者缺一不可：
    // - 只在 `runAsync` 里等：真实网络能推进，但**组件树不重建**（`pump` 才重建），
    //   于是 `find` 永远看到点击前那一帧 —— 循环会立刻判成"已结束"（实测踩过）；
    // - 只用 `pumpAndSettle`：它等的是"没有待处理的帧"，而真网络请求期间页面一直在变
    //   （进度文案），于是它一直等到超时（第一版"did not complete、无原因"的成因）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (find.text(text).evaluate().isNotEmpty) return true;
  }
  return false;
}

/// 页面上所有"（…）"形式的错误文案（失败时打出来，否则只看到"找不到卡片"）。
String _errorText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.contains('（') && s.contains('）'))
    .join(' | ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机：粘贴真二维码 → 两段配对 → 拿到设备令牌并落进 Keystore', (tester) async {
    if (_qrPayload.isEmpty) {
      // 前置没给就跳过：见文件头（"前置没起"与"实现不对"是两件事）。
      markTestSkipped('未提供 DSH_QR_PAYLOAD：这条用例需要一台在跑的中转与连接器');
      return;
    }

    // 清掉上一次的凭据：否则"配对成功"可能来自旧凭据，用例会假通过。
    await pairingStore.clear();

    PairingResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: PairingPage(
          // **真的 HTTP**（换票）与**真的 WS**（受限通道）—— 这条用例要的就是真。
          send: createHttpSender(),
          transportFor: _pairingTransport,
          allowInsecureLocal: true,
          onPaired: (result) async {
            captured = result;
            // 与装配点同一条路径：配对结果进安全存储。
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

    await tester.enterText(find.byType(TextField), _qrPayload);
    await tester.tap(find.text('连接电脑'));

    // 第一段：换票 → 升级 → 受限握手。走完会显示身份卡（**秘密还没发出去**）。
    final ready = await _waitForText(tester, '通道已就绪，等待你确认');
    expect(
      ready,
      isTrue,
      reason: '受限通道应当建起来（换票 → 升级 → 握手）；页面上的错误：${_errorText(tester)}',
    );
    // 身份卡上的每一样都来自二维码：用户核对的就是"我扫的是这台电脑"。
    expect(find.textContaining('conn'), findsWidgets, reason: '身份卡要显示电脑标识');

    // 第二段：**用户确认**才提交秘密。
    //
    // 先收软键盘：`enterText` 会唤起键盘，而它盖住页面下半部分 ——
    // 确认按钮正好在那里。少了这一步，`tap` 报 "widget is actually off-screen"
    // 并给出一个满是 `RenderAnimatedOpacity` 的 hit-test 结果（那就是键盘的浮层）。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并配对'));

    final done = await _waitForText(tester, '配对成功');
    expect(
      done,
      isTrue,
      reason: '提交后应当拿到回执（含设备令牌）；页面上的错误：${_errorText(tester)}',
    );

    // SAS 要**真的显示出来**：它虽不参与授权判定，却是两端各算一遍的辅助指纹
    // （对不上说明双方看到的不是同一组公钥）。
    //
    // 判据取 SAS 那六个格子的**尺寸**（`pairing_page.dart` 的 `_SasDisplay`：26×34）——
    // 比"数页面上所有单个数字"更贴近"用户看到六个格子"这件事。后者会把步骤编号
    // （1、2、3）也数进来（实测踩过一次：期望 6、实际 8）。
    final sasCells = tester.widgetList<Container>(find.byType(Container)).where(
      (c) {
        final d = c.constraints;
        return d != null && d.maxWidth == 26 && d.maxHeight == 34;
      },
    ).length;
    expect(sasCells, 6, reason: 'SAS 六位数字都要显示出来；实际 $sasCells 个格子');

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
    await tester.pump(const Duration(milliseconds: 100));
    expect(captured, isNotNull, reason: '点"完成"之后必须回调 onPaired');
    expect(captured!.sas, matches(RegExp(r'^\d{6}$')));
    expect(captured!.deviceToken, isNotEmpty, reason: '回执必须带设备令牌');
    expect(captured!.refreshToken, isNotEmpty);
    expect(captured!.pcId, isNotEmpty, reason: '回执必须带 pcId（握手 transcript 用它）');
    expect(captured!.devId, isNotEmpty);
    // `pairingId` 是**手机自己算的**（不在回执里），32 字节 base64url 无填充。
    expect(captured!.pairingId.length, 43);

    // **真的落到设备密钥库**：这是纯单测验不了的一段（插件在 Dart VM 里没有实现）。
    final stored = await pairingStore.load();
    expect(stored, isNotNull, reason: '配对结果必须真的落进安全存储');
    expect(stored!.deviceToken, captured!.deviceToken);
    expect(stored.devId, captured!.devId);

    // 收尾：清掉，免得影响下一次跑（也会让凭据留在设备上）。
    await pairingStore.clear();
  });
}
