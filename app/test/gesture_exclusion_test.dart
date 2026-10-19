/// 系统手势排除的回归（`platform/gesture_exclusion.dart` + `ui/edge_handles.dart`）。
///
/// 守的是**"我们真的把那两块边报给了系统，而且形状对"**：2026-10-16 真机实测，
/// 不报的话从最外缘划一下会被系统返回吃掉、**App 直接退回桌面**；报了才轮到我们的手势。
/// 这条链以前只活在笔记里，现在有断言：
///
/// 1. 逻辑坐标 → **物理像素**（系统只认物理像素）；
/// 2. 每条带子的高度 ≤ **200dp**（官方上限；超了系统只认最靠下的那段）；
/// 3. 带子贴**屏幕最边缘**（内缩到 36dp 那一版被用户否了）；
/// 4. 通道没接（iOS / 桌面）时如实回 false，不假装成功。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/platform/gesture_exclusion.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

const _channel = MethodChannel('dsh/gesture-exclusion');

/// 一个什么都不回的假客户端（这条用例只要聊天页能建起来）。
class _QuietClient extends FakeSyncClient {
  @override
  ConnectionState get state => ConnectionState.idle;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => null as T;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('excludeSystemGestureRects：只做换算与转发', () {
    test('逻辑坐标换算成物理像素，两块矩形一次过通道', () async {
      final calls = <MethodCall>[];
      _mock(calls);

      final ok = await excludeSystemGestureRects([
        const Rect.fromLTRB(0, 72, 32, 264), // 左带：192dp 高
        const Rect.fromLTRB(368, 72, 400, 264), // 右带
      ], devicePixelRatio: 2.625);

      expect(ok, isTrue, reason: 'Android 10+ 会回 true');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setRects');
      expect((calls.single.arguments as Map)['rects'], [
        0, 189, 84, 693, // 72/32/264 × 2.625
        966, 189, 1050, 693, // 368/400 × 2.625
      ], reason: '系统只认物理像素');
    });

    test('通道没接（iOS / 桌面 / 未接线）时回 false，不假装成功', () async {
      // 这一条不注册替身：`invokeMethod` 会抛 MissingPluginException，
      // 而这一层必须把它变成"没接"，不是异常。
      final ok = await excludeSystemGestureRects([
        const Rect.fromLTRB(0, 0, 32, 192),
      ], devicePixelRatio: 2);
      expect(ok, isFalse);
    });
  });

  group('边把手真的把带子报上去了', () {
    testWidgets('两块带子：贴最边缘、高度 ≤200dp、各报一次', (tester) async {
      final calls = <MethodCall>[];
      _mock(calls);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, null),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: AppModel(client: _QuietClient()),
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rects = _lastRects(calls);
      expect(rects, hasLength(2), reason: '左带 + 右带');

      final dpr = tester.view.devicePixelRatio;
      final left = rects[0];
      final right = rects[1];
      // 贴最边缘：左边那块 left == 0；右边那块 right == 屏宽。
      expect(left.left, 0, reason: '把手/带子在最左缘（不许内缩）');
      expect(right.right / dpr, 800, reason: '右带贴最右缘');
      // 高度：官方上限 200dp。
      for (final rect in rects) {
        final heightLogical = (rect.bottom - rect.top) / dpr;
        expect(
          heightLogical,
          lessThanOrEqualTo(200),
          reason: '每条边最多排除 200dp（超了系统只认最靠下的那段）',
        );
        expect(heightLogical, greaterThan(0));
      }
      // 只报一次：build 重跑不该每次都往系统喊。
      final before = calls.length;
      await tester.pump();
      expect(calls.length, before, reason: '同一组矩形只报一次');
    });
  });
}

/// 起一个假的平台通道，把调用记进 [calls]。
void _mock(List<MethodCall> calls) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return true;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );
}

/// 取最后一次 `setRects` 的矩形（每 4 个一组）。
List<Rect> _lastRects(List<MethodCall> calls) {
  final flat = (calls.last.arguments as Map)['rects'] as List;
  final out = <Rect>[];
  for (var i = 0; i + 3 < flat.length; i += 4) {
    out.add(
      Rect.fromLTRB(
        (flat[i] as int).toDouble(),
        (flat[i + 1] as int).toDouble(),
        (flat[i + 2] as int).toDouble(),
        (flat[i + 3] as int).toDouble(),
      ),
    );
  }
  return out;
}
