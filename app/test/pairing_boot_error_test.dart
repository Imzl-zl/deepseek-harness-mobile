/// 安全存储读取失败必须可见，不清数据、不重建设备码。
library;

import 'package:dsh_mobile/data/app_services.dart';
import 'package:dsh_mobile/main.dart';
import 'package:dsh_mobile/platform/notify_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('启动安全存储读错显示原因和重试，而不是无限启动圈', (tester) async {
    const channel = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'test-secure-read-failed');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      DshMobileApp(services: AppServices(notify: MemoryNotify())),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '读取失败被显式呈现，不能漏成未处理异常');
    expect(find.textContaining('test-secure-read-failed'), findsOneWidget);
    expect(find.text('重试读取'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      calls.every((method) => method == 'readAll'),
      isTrue,
      reason: '读失败不能deleteAll或生成新设备码',
    );
    await tester.pumpWidget(const SizedBox());
  });
}
