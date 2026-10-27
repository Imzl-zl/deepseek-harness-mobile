import 'package:dsh_mobile/data/composer_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 发送门槛的唯一入口（`data/composer_gate.dart`）。
///
/// ## 判据出处
///
/// 桌面 `packages/client/ui-conversation/src/client/skeleton/InputBar.tsx:343`：
/// `primaryDisabled = primaryStops ? stopAction === undefined
///   : empty || disabled || machineBusy || uploadsPending`；
/// `:341` 的 `primaryStops = running && subagent === null && (empty || blocked !== undefined)`；
/// `:154` 的 `disabled = removed || inert || !live || blocked !== undefined || parentOffline`；
/// 以及 `skeleton/ConversationContent.tsx:142` 的 `inert = sessionId === undefined || (hero && chipTitle === undefined)`。
///
/// ## 手机侧去掉的三项（各有理由，见设计 §4）
///
/// `machineBusy`（手机没有输入机状态机）、`uploadsPending`（手机没有宿主上传阶段）、
/// `blocked`（本版 DSH 无任何 feature 调用 `blocks.set`）。
///
/// ## 本文件锁住的不变量
///
/// 1. **"未选模型"永远不是门槛** —— 用一个反例钉死：枚举里出现模型相关档位即红。
/// 2. 正文空时**不给话**（桌面 `empty` 只禁用，不弹文案）。
/// 3. 只有 `GateBlocked` 带句子，且句子来自唯一常量。
void main() {
  /// 一个"什么都不缺"的基线：能发。
  ComposerGate ready({
    bool paired = true,
    String? sid = 'sid-1',
    bool blankSession = false,
    bool workspaceResolved = true,
    String? subagentReadOnlySentence,
    bool parentOffline = false,
    bool draftEmpty = false,
    bool sending = false,
    bool canStop = false,
  }) => composerGateOf(
    paired: paired,
    sid: sid,
    blankSession: blankSession,
    workspaceResolved: workspaceResolved,
    subagentReadOnlySentence: subagentReadOnlySentence,
    parentOffline: parentOffline,
    draftEmpty: draftEmpty,
    sending: sending,
    canStop: canStop,
  );

  test('基线：有会话、有正文、没在跑 → 发送', () {
    expect(ready(), isA<ComposerGateSend>());
  });

  group('被挡时必须说清缺什么（GateBlocked 才带句子）', () {
    test('没配对：先连电脑', () {
      final gate = ready(paired: false);
      expect(gate, isA<ComposerGateBlocked>());
      final blocked = gate as ComposerGateBlocked;
      expect(blocked.reason, ComposerGateReason.notPaired);
      expect(blocked.sentence, ComposerGateCopy.notPaired);
      expect(blocked.sentence, isNotEmpty);
    });

    test('没选会话：句子就是既有那句（不新造）', () {
      final gate = ready(sid: null);
      expect(gate, isA<ComposerGateBlocked>());
      final blocked = gate as ComposerGateBlocked;
      expect(blocked.reason, ComposerGateReason.noSession);
      expect(blocked.sentence, '先在列表里选一个会话，再发消息');
    });

    test('blank 会话且工作区解析不出来：挡住（桌面 inert）', () {
      final gate = ready(blankSession: true, workspaceResolved: false);
      expect(gate, isA<ComposerGateBlocked>());
      final blocked = gate as ComposerGateBlocked;
      expect(blocked.reason, ComposerGateReason.noWorkspace);
      // 与 hero 上那枚 chip 的占位同一句（`conversation_hero.dart` 同源常量）。
      expect(blocked.sentence, '选择工作区');
    });

    test('非 blank 会话不受工作区影响（桌面只看 hero 的 chipTitle）', () {
      final gate = ready(blankSession: false, workspaceResolved: false);
      expect(gate, isA<ComposerGateSend>());
    });

    test('子会话只读：句子由上层给（同一份文案）', () {
      final gate = ready(subagentReadOnlySentence: '一次性子会话，不能续聊');
      expect(gate, isA<ComposerGateBlocked>());
      final blocked = gate as ComposerGateBlocked;
      expect(blocked.reason, ComposerGateReason.subagentReadOnly);
      expect(blocked.sentence, '一次性子会话，不能续聊');
    });

    test('父会话不在线：挡住（桌面 parentOffline 只是置灰，手机必须说）', () {
      final gate = ready(parentOffline: true);
      expect(gate, isA<ComposerGateBlocked>());
      final blocked = gate as ComposerGateBlocked;
      expect(blocked.reason, ComposerGateReason.parentOffline);
      expect(blocked.sentence, ComposerGateCopy.parentOffline);
    });
  });

  group('主键优先级（照桌面 primaryStops 先于 primaryDisabled）', () {
    test('在跑 + 正文空 + 能停 → 停止', () {
      expect(ready(draftEmpty: true, canStop: true), isA<ComposerGateStop>());
    });

    test('在跑 + 正文空 + 被挡 + 能停 → 仍是停止（桌面先判 primaryStops）', () {
      expect(
        ready(draftEmpty: true, canStop: true, parentOffline: true),
        isA<ComposerGateStop>(),
      );
    });

    test('在跑 + 正文空 + 不能停 → 挡住（桌面此时 primaryDisabled = true）', () {
      final gate = ready(draftEmpty: true, canStop: false, parentOffline: true);
      expect(gate, isA<ComposerGateBlocked>());
    });

    test('在跑 + 有正文 → 发送（可排队/插话）', () {
      expect(ready(canStop: true), isA<ComposerGateSend>());
    });
  });

  group('静默禁用：正文空 / 请求在途 —— 一律不带句子', () {
    test('正文空 → 静默禁用', () {
      expect(ready(draftEmpty: true), isA<ComposerGateDisabled>());
    });

    test('请求在途 → 静默禁用', () {
      expect(ready(sending: true), isA<ComposerGateDisabled>());
    });

    test('请求在途但被挡 → 优先说清缺什么', () {
      final gate = ready(sending: true, parentOffline: true);
      expect(gate, isA<ComposerGateBlocked>());
    });
  });

  test('哪些句子会替换占位文案：只有"会话在、缺前提"那三档', () {
    ComposerGateBlocked blockedOf(ComposerGate gate) =>
        gate as ComposerGateBlocked;

    // 不替换：出路在空态与顶栏，占位文案是交互基线的一部分。
    expect(
      blockedOf(ready(paired: false)).replacesPlaceholder,
      isFalse,
      reason: '没配对：出路是"连电脑"，不是把占位文案改成一句提示',
    );
    expect(
      blockedOf(ready(sid: null)).replacesPlaceholder,
      isFalse,
      reason: '没选会话：原型与 widget_test 的占位符是基线文案',
    );
    // 替换：这条会话缺前提，用户再不点就不知道缺什么。
    expect(
      blockedOf(
        ready(blankSession: true, workspaceResolved: false),
      ).replacesPlaceholder,
      isTrue,
    );
    expect(
      blockedOf(ready(subagentReadOnlySentence: '只读')).replacesPlaceholder,
      isTrue,
    );
    expect(blockedOf(ready(parentOffline: true)).replacesPlaceholder, isTrue);
  });

  test('不变量：门槛里没有"未选模型"这一档（添加即红）', () {
    // 桌面发送门槛不含模型（`InputBar.tsx:343` + `:154`），
    // 会话没有记录选择时活跟随宿主默认（`api/session-controller/src/agent.ts:464-472`）。
    expect(
      ComposerGateReason.values.map((r) => r.name),
      isNot(contains('noModel')),
    );
    expect(
      ComposerGateReason.values.map((r) => r.name),
      unorderedEquals(<String>[
        'notPaired',
        'noSession',
        'noWorkspace',
        'subagentReadOnly',
        'parentOffline',
      ]),
    );
  });
}
