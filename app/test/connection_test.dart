/// 连接状态机、退避、心跳与半开（契约 §2.2、§9、§10）。
///
/// 这三件是"写错也不会让协议规格变红"的判据 —— 它们不参与 fixtures 或向量，
/// 但它们的错误表现是最难查的一类：**连接看起来正常，只是永远收不到东西**。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/keepalive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('连接状态机（契约 §2.2）', () {
    test('合法路径：idle → connecting → handshake → serving → closed → backoff', () {
      final machine = ConnectionMachine();
      expect(machine.state, ConnectionState.idle);
      machine.to(ConnectionState.connecting);
      machine.to(ConnectionState.handshake);
      machine.to(ConnectionState.serving);
      machine.to(ConnectionState.closed);
      machine.to(ConnectionState.backoff);
      machine.to(ConnectionState.connecting);
      expect(machine.state, ConnectionState.connecting);
    });

    test('非法迁移抛错 —— 状态机的全部价值就在这里', () {
      // 允许任意跳转的话，真正的 bug（从 idle 直接进 serving、backoff 里又开一条连接）
      // 会静默发生，表现为**两条连接同时存在**。
      final machine = ConnectionMachine();
      expect(
        () => machine.to(ConnectionState.serving),
        throwsA(isA<IllegalTransitionError>()),
        reason: 'idle 不能直接进 serving',
      );
      machine.to(ConnectionState.connecting);
      expect(
        () => machine.to(ConnectionState.backoff),
        throwsA(isA<IllegalTransitionError>()),
        reason: 'connecting 不能直接进退避',
      );
    });

    test('只有 serving 才接受业务帧（握手期只放行握手帧与配对帧）', () {
      final machine = ConnectionMachine();
      expect(machine.acceptsBusinessFrames, isFalse);
      machine.to(ConnectionState.connecting);
      expect(machine.acceptsBusinessFrames, isFalse);
      machine.to(ConnectionState.handshake);
      expect(
        machine.acceptsBusinessFrames,
        isFalse,
        reason: '握手期收业务帧是攻击面，不是"宽容"',
      );
      machine.to(ConnectionState.serving);
      expect(machine.acceptsBusinessFrames, isTrue);
    });

    test('isAnyOf 按集合判断；迁移通知按顺序派发', () {
      final machine = ConnectionMachine();
      expect(machine.isAnyOf([ConnectionState.idle]), isTrue);
      final seen = <String>[];
      machine.onChange((from, to) => seen.add('${from.name}->${to.name}'));
      machine.to(ConnectionState.connecting);
      machine.to(ConnectionState.handshake);
      expect(seen, ['idle->connecting', 'connecting->handshake']);
    });

    test('取消订阅后不再收到通知', () {
      final machine = ConnectionMachine();
      final seen = <ConnectionState>[];
      final off = machine.onChange((_, to) => seen.add(to));
      machine.to(ConnectionState.connecting);
      off();
      machine.to(ConnectionState.handshake);
      expect(seen, [ConnectionState.connecting]);
    });

    test('监听器里取消订阅不会让派发崩（并发修改）', () {
      // 复制一份再遍历：监听器里取消订阅是常见写法。
      final machine = ConnectionMachine();
      final seen = <ConnectionState>[];
      void Function()? off;
      off = machine.onChange((_, to) {
        seen.add(to);
        off?.call();
      });
      expect(() => machine.to(ConnectionState.connecting), returnsNormally);
      expect(() => machine.to(ConnectionState.handshake), returnsNormally);
      expect(seen, [ConnectionState.connecting]);
    });
  });

  group('退避（契约 §2.2、§10）', () {
    test('指数增长并封顶 30 s（抖动注入为 0 时是确定值）', () {
      // `random() = 0.5` ⇒ 抖动系数 `(0.5*2-1)*0.2 = 0` ⇒ 无抖动。
      final backoff = Backoff(random: () => 0.5);
      expect(backoff.next(), 1000);
      expect(backoff.next(), 2000);
      expect(backoff.next(), 4000);
      expect(backoff.next(), 8000);
      expect(backoff.next(), 16000);
      expect(backoff.next(), 30000, reason: '封顶');
      expect(backoff.next(), 30000, reason: '一直封顶');
    });

    test('抖动落在 ±20% 内，且不顶破上界', () {
      final low = Backoff(random: () => 0.0); // 系数 -0.2
      expect(low.next(), 800, reason: '1000 × 0.8');
      final high = Backoff(random: () => 1.0); // 系数 +0.2
      expect(high.next(), 1200, reason: '1000 × 1.2');

      // 上界不能被抖动顶破：30 s × 1.2 仍是 30 s。
      final capped = Backoff(random: () => 1.0);
      for (var i = 0; i < 6; i += 1) {
        capped.next();
      }
      expect(capped.next(), 30000);
    });

    test('reset 回到起点（连接成功后必须调，否则下次从大间隔开始）', () {
      final backoff = Backoff(random: () => 0.5);
      backoff.next();
      backoff.next();
      expect(backoff.attempt, 2);
      backoff.reset();
      expect(backoff.attempt, 0);
      expect(backoff.next(), 1000);
    });

    test('大 attempt 不溢出（乘法逐步夹住上界）', () {
      final backoff = Backoff(random: () => 0.5);
      for (var i = 0; i < 200; i += 1) {
        final value = backoff.next();
        expect(value, inInclusiveRange(0, 30000));
      }
    });

    test('连续失败到阈值就放弃：电脑关机时不该永远转圈', () {
      // 2026-10-15 真机反馈："我电脑关机了,早上来了,手机一直重连,
      // 没有说重连多久连不上然后就停止,提示连接不上啥的"。
      final backoff = Backoff(random: () => 0.5);
      expect(backoff.exhausted, isFalse, reason: '一次都没失败不该判放弃');
      for (var i = 0; i < Backoff.defaultMaxAttempts - 1; i += 1) {
        backoff.next();
        expect(backoff.exhausted, isFalse, reason: '第 ${i + 1} 次失败还在容忍范围内');
      }
      backoff.next();
      expect(backoff.attempt, Backoff.defaultMaxAttempts);
      expect(backoff.exhausted, isTrue, reason: '到阈值必须放弃,让界面给结论');
    });

    test('阈值可注入：测试不必真等 3 分钟', () {
      final backoff = Backoff(random: () => 0.5, maxAttempts: 2);
      backoff.next();
      expect(backoff.exhausted, isFalse);
      backoff.next();
      expect(backoff.exhausted, isTrue);
    });

    test('reset 同时清掉放弃标记（否则手动重试后会立刻又判放弃）', () {
      final backoff = Backoff(random: () => 0.5, maxAttempts: 1);
      backoff.next();
      expect(backoff.exhausted, isTrue);
      backoff.reset();
      expect(backoff.exhausted, isFalse);
      expect(backoff.next(), 1000, reason: '间隔也回到起点');
    });
  });

  group('心跳与半开（契约 §2.2、§9）', () {
    test('空闲满一个心跳周期发一次 ping，且一个空闲期只发一次', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      keepalive.onFrame(0);
      // 不到一个周期：什么都不做。
      expect(keepalive.tick(500), isA<KeepaliveIdle>());
      // 满一个周期：发 ping。
      expect(keepalive.tick(1000), isA<KeepalivePing>());
      // 同一空闲期再 tick：不再发（否则每 tick 都发，半开永远攒不满）。
      expect(keepalive.tick(1100), isA<KeepaliveIdle>());
      expect(keepalive.tick(1900), isA<KeepaliveIdle>());
    });

    test('任一方向连续 2 个周期无帧 → 判半开（TCP 半开不会报错）', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      keepalive.onFrame(0);
      // 发 ping 会重置空闲计时（心跳本身是一帧）—— 所以半开要从"ping 之后"数。
      expect(keepalive.tick(1000), isA<KeepalivePing>());
      expect(keepalive.tick(1500), isA<KeepaliveIdle>());
      // ping 之后又过了 2000 ms（两个周期）都没收到任何帧 → 半开。
      final action = keepalive.tick(3000);
      expect(action, isA<KeepaliveHalfOpen>());
      expect((action as KeepaliveHalfOpen).silentMs, 2000);
    });

    test('收到任何帧都重置空闲计时（收与发都算）', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      keepalive.onFrame(0);
      expect(keepalive.tick(1000), isA<KeepalivePing>());
      // 对端回了 pong（或我们发了别的帧）：计时归零。
      keepalive.onFrame(1000);
      expect(keepalive.tick(1500), isA<KeepaliveIdle>(), reason: '刚有帧，不该判半开');
      expect(
        keepalive.tick(2000),
        isA<KeepalivePing>(),
        reason: '新的空闲期，可以再 ping',
      );
    });

    // 原本这里有一条「后台不发心跳，但半开判定照旧」——随契约 §9 的规则一起删：
    // 心跳现在不分前后台（后台连接由前台服务维持，见 §13 的安卓例外），
    // 停心跳只会把一条健康连接在 2 个周期后判死。
    test('空闲到心跳间隔就发 ping（不分前后台）', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      keepalive.onFrame(0);
      expect(keepalive.tick(1000), isA<KeepalivePing>());
      // ping 本身重置空闲计时 ⇒ 半开要再静默满 2 个周期。
      expect(keepalive.tick(3000), isA<KeepaliveHalfOpen>());
    });

    test('第一次 tick 以自己为基准（不把"启动到现在"算成沉默）', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      // 没有 onFrame，直接 tick 一个很大的 now：不该立刻判半开。
      expect(keepalive.tick(999999), isA<KeepaliveIdle>());
    });

    test('silentFor 与 halfOpenAfterMs 是自检面', () {
      final keepalive = Keepalive(heartbeat: 1000, periods: 2);
      expect(keepalive.halfOpenAfterMs, 2000);
      keepalive.onFrame(100);
      expect(keepalive.silentFor(600), 500);
    });
  });
}
