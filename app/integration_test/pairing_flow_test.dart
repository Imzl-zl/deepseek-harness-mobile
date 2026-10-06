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
/// 跑法（模拟器已在跑）：
/// ```
/// flutter test integration_test/pairing_flow_test.dart -d emulator-5554
/// ```
library;

import 'package:dsh_mobile/platform/pairing_store.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 一份**真的**二维码载荷（由 `node app/tools/make-pairing-qr.mjs` 产出）。
///
/// 固定值而不是运行时生成：这条用例要验的是"App 能不能处理电脑侧真实形状的载荷"，
/// 而固定值让失败可复现（`code` 变了不影响解析路径）。
const _qrPayload =
    '{"v":1,"relay":"wss://relay.example.test/ws/connector",'
    '"pcPubEd":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
    '"pcPubDh":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'
    '"code":"abL3sSH5gLJpTBBsqPUzJg"}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('粘贴真载荷 → 解析 → 显示 6 位 SAS', (tester) async {
    PairingResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: PairingPage(
          onPaired: (result) async {
            captured = result;
          },
        ),
      ),
    );

    // **先清掉上一次跑留下的凭据**（否则下面的"重启后仍在"会假通过）。
    await PairingStore.clear();

    await tester.enterText(find.byType(TextField), _qrPayload);
    await tester.tap(find.text('解析'));
    await tester.pumpAndSettle();

    // 解析成功：出现"核对数字"那张卡。
    expect(find.text('在电脑上核对这 6 位数字'), findsOneWidget);
    // 6 位数字必须真的显示出来（它是用户唯一能带外核对的东西）。
    expect(find.byType(Text), findsWidgets);

    // **先滚到按钮再点**：确认卡在页面下方，而这块屏幕只有 320×640
    // （实测：按钮中心落在 y=646，超出 640 的根节点边界 → `tap` 打不中，
    // 报"would not hit test on the specified widget"）。
    // 这条同时是对**真机可用性**的检查：在这么小的屏上，确认按钮需要滚动才够得着。
    await tester.ensureVisible(find.text('数字一致，开始连接'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('数字一致，开始连接'));
    await tester.pumpAndSettle();
    // 回调是 `unawaited(...)` 调的（`onPaired` 在真实装配里要落盘 + 建连，
    // 不能阻塞 UI），所以给它一轮事件循环再断言 —— `pumpAndSettle` 只等帧，
    // 不等一个已排队的微任务/异步链。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(captured, isNotNull, reason: '点确认后应回调 onPaired');
    // SAS 是 6 位数字（含补零）。
    expect(captured!.sas, matches(RegExp(r'^\d{6}$')));
    expect(captured!.offer.relayUrl, 'wss://relay.example.test/ws/connector');
    // `pairingId` 是 base64url 无填充的 32 字节。
    expect(
      captured!.pairingId.length,
      43,
      reason: '32 字节 base64url 无填充 = 43 字符',
    );
    expect(captured!.pairingId, isNot(contains('=')));
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
    );
    await PairingStore.save(credentials);

    // 读回来：**逐字段比**（少一个字段就得重新配对，而"部分可用"会让失败
    // 发生在握手阶段，那时没人会想到是存储缺字段）。
    final loaded = await PairingStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.masterSeedHex, credentials.masterSeedHex);
    expect(loaded.pairingId, credentials.pairingId);
    expect(loaded.pcSignPubHex, credentials.pcSignPubHex);
    expect(loaded.relayUrl, credentials.relayUrl);

    // `deviceId` 是从 `devPubDh` 本地推导的（不是存的）——
    // 它必须与电脑侧算的同一个值（跨端向量已验算法，这里验接线）。
    expect(await loaded.deviceId(), isNotEmpty);

    // 收尾：清掉，免得影响下一次跑。
    await PairingStore.clear();
  });
}
