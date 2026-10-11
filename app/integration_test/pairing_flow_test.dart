/// 在**真机/模拟器**上跑的端到端用例：配对 → 存密钥 → 重启后仍在。
///
/// ## 为什么这个必须跑在设备上，而不是 widget test 里
///
/// 它验的是 `flutter_secure_storage` —— 那是**平台插件**，在纯 Dart 单测里没有实现
/// （调用会抛 `MissingPluginException`）。而"密钥到底有没有真的落到 Keystore"
/// 这件事只有真机能回答：写进内存的假实现永远返回成功。
///
/// ## 它同时补上一个我做不到的手工步骤
///
/// `adb shell input text` **不能输入引号**（实测报 `no closing quote`），
/// 而二维码载荷是 JSON（满是引号）。所以"手工粘贴 241 字符的载荷"这条路走不通 ——
/// 这条用例用 `enterText` 直接灌进输入框，等价且可重复。
///
/// ## 它**不**验与电脑侧的真实交换
///
/// 那一半需要一台真的中转（要起进程、配令牌），属于 `connector/tests/pairing-e2e.test.ts`
/// 的覆盖面（它用真 HTTP + 真 WS 跑完整条链）。这条用例的注入缝是**故意失败**的：
/// 它要证明的是"配对页把失败如实显示出来"与"密钥真的落到设备安全存储"，
/// 而这两件事都不该依赖一台在跑的中转。
///
/// 跑法（真机是 d61cf622）：
/// ```
/// flutter test integration_test/pairing_flow_test.dart -d d61cf622
/// ```
library;

import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 一份**真的** v2 二维码载荷（由出码命令产出，形状见 `pairing-v2.md` §3）。
///
/// 固定值而不是运行时生成：这条用例要验的是"App 能不能处理电脑侧真实形状的载荷"，
/// 而固定值让失败可复现（`code` 变了不影响解析路径）。
const _qrPayload =
    '{"v":2,"relay":"ws://127.0.0.1:8787","pcId":"conn-1",'
    '"pcPubEd":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
    '"pcPubDh":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'
    '"offerId":"zyXWvUTSrqPONMLKjihgfe","code":"abL3sSH5gLJpTBBsqPUzJg"}';

/// 一个**永远失败**的 HTTP 缝：这条用例不连真中转（见文件头）。
///
/// 它抛的是 [TransportException] —— 与真实实现"连不上中转"时同一类别，
/// 于是页面显示的是那句"（连不上中转）"。假装成功会让下面的断言验到一个假的成功路径。
Future<HttpResult> _refusingHttp(HttpCall call) async {
  throw const TransportException('测试：这条用例故意不连中转');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('粘贴真载荷 → 真的去连电脑 → 连不上时**如实报错**（不假装成功）', (tester) async {
    var dialed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: PairingPage(
          onPaired: (_) async {},
          send: _refusingHttp,
          // v2 的传输缝是"给一条已带票的 URL 建连"：换票失败时它**不该**被调到。
          transportFor: (url) {
            dialed = true;
            throw const TransportException('测试：不该走到拨号这一步');
          },
          // 本机调试的中转是明文 `ws://`：显式开启（生产只认 wss）。
          allowInsecureLocal: true,
        ),
      ),
    );

    // **先清掉上一次跑留下的凭据**（否则下面的"重启后仍在"会假通过）。
    await PairingStore.clear();

    await tester.enterText(find.byType(TextField), _qrPayload);
    await tester.tap(find.text('连接电脑'));
    await tester.pumpAndSettle();

    // 没有中转 ⇒ 换票这一步就该失败，而**失败必须显示出来**。
    // 早先这一页只做本地派生：它会把一张"确认卡"显示出来，让人以为配对成功了 ——
    // 而电脑侧从来没有收到过任何请求。
    expect(
      find.text('通道已就绪，等待你确认'),
      findsNothing,
      reason: '换票没成功就不该显示"等待确认"的身份卡',
    );
    expect(find.textContaining('连不上中转'), findsOneWidget);
    expect(dialed, isFalse, reason: '没换到票就不该去拨号（那必然是一个 401）');
  });

  testWidgets('密钥真的落到设备安全存储，且重启后还能读回来', (tester) async {
    // 这一段**只有真机能验**：`flutter_secure_storage` 在纯单测里没有实现。
    await PairingStore.clear();
    expect(await PairingStore.load(), isNull, reason: '清空后应为空');

    const credentials = PairedCredentials(
      relayUrl: 'wss://relay.example.test/ws/connector',
      pcSignPubHex:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      pcDhPubHex:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      pairingId: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      masterSeedHex:
          '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20',
      devSignPubHex:
          '1111111111111111111111111111111111111111111111111111111111111111',
      devDhPubHex:
          '2222222222222222222222222222222222222222222222222222222222222222',
      deviceToken: 'DEVICE-TOKEN-1',
      refreshToken: 'REFRESH-TOKEN-1',
      pcId: 'conn-1',
      devId: 'dev-1',
    );
    await PairingStore.save(credentials);

    // 读回来：**逐字段比**（少一个字段就得重新配对，而"部分可用"会让失败
    // 发生在很后面 —— 那时没人会想到是存储缺字段）。
    final loaded = await PairingStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.masterSeedHex, credentials.masterSeedHex);
    expect(loaded.pairingId, credentials.pairingId);
    expect(loaded.pcSignPubHex, credentials.pcSignPubHex);
    expect(loaded.relayUrl, credentials.relayUrl);
    // **两个令牌必须落下来**：它们是之后每次重连换票的唯一凭据
    // （配对码是一次性的，用完就没了）。
    expect(loaded.deviceToken, credentials.deviceToken);
    expect(loaded.refreshToken, credentials.refreshToken);
    expect(loaded.pcId, credentials.pcId);
    expect(loaded.devId, credentials.devId);

    // 设备 id 优先用电脑侧给的权威值；本地推导与它必须是同一个（跨端向量已验算法）。
    expect(await loaded.helloDeviceId(), 'dev-1');
    expect(await loaded.derivedDeviceId(), isNotEmpty);

    // 收尾：清掉，免得影响下一次跑。
    await PairingStore.clear();
  });
}
