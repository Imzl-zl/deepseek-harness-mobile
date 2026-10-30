/// 设备本地状态缝（`data/ui_state.dart`）的契约。
///
/// ## 它守的三件事
///
/// 1. **键的分类**：`device.*` 与某台电脑无关（换电脑保留）；
///    `host.*` 属于某台电脑（重新配对要整段清）。谁都不能两边都住。
/// 2. **失效规则**：会话从清单消失 / 工作区被删 / 换电脑 —— 三种 prune 各自只删该删的。
/// 3. **恢复点在首帧前**：`open()` 一次读完，之后读是同步 getter（不阻塞 build）。
///
/// Note: 语义与判据见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §2。
library;

import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/data/ui_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存偏好缝（`PreferenceStore` 的测试实现），带"调用了几次写"的计数。
class _MemPrefs implements PreferenceStore {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in values.entries)
      if (entry.key == prefix || entry.key.startsWith(prefix))
        entry.key: entry.value,
  };

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    values[key] = value;
  }

  @override
  Future<void> delete(String prefix, {bool includePrefixed = true}) async =>
      values.removeWhere(
        (key, _) =>
            key == prefix || (includePrefixed && key.startsWith(prefix)),
      );
}

void main() {
  late _MemPrefs prefs;
  late UiStateStore ui;

  setUp(() async {
    prefs = _MemPrefs();
    ui = UiStateStore(prefs: prefs);
    await ui.open();
  });

  group('device.*：与某台电脑无关，换电脑也保留', () {
    test('没存过 → null（不拿默认值冒充）', () {
      expect(ui.themeMode, isNull);
      expect(ui.uiScaleIndex, isNull);
      expect(ui.transcriptView, isNull);
      expect(ui.performanceView, isNull);
      expect(ui.collapseTiming, isNull);
    });

    test('写后能读回，且键就是约定名', () async {
      await ui.setThemeMode('dark');
      await ui.setUiScaleIndex(2);
      await ui.setTranscriptView('detailed');
      expect(prefs.values[UiKey.themeMode], 'dark');
      expect(prefs.values[UiKey.uiScaleIndex], '2');
      expect(prefs.values[UiKey.transcriptView], 'detailed');

      // 新建一个 store 也能读回（= 重启）。
      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(again.themeMode, 'dark');
      expect(again.uiScaleIndex, 2);
    });

    test('认不出的值保持 null（调用方用默认，不猜）', () async {
      prefs.values[UiKey.uiScaleIndex] = '不是数字';
      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(again.uiScaleIndex, isNull);
    });

    test('同一个值重复写是空操作（不产生第二次落盘）', () async {
      await ui.setThemeMode('dark');
      final before = prefs.writes;
      await ui.setThemeMode('dark');
      expect(prefs.writes, before);
    });
  });

  group('host.*：属于某台电脑', () {
    test('上次看的会话：写后跨重启读回，传 null 是删', () async {
      await ui.setLastSession('sid-1');
      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(again.lastSession, 'sid-1');

      await again.setLastSession(null);
      expect(prefs.values.containsKey(UiKey.lastSession), isFalse);
    });

    test('抽屉折叠：按 workspaceId 合并，不丢别的组', () async {
      expect(ui.drawerExpandedOf('w1'), isNull, reason: '没记过 = 调用方按"展开"处理');
      await ui.setWorkspaceExpanded('w1', false);
      await ui.setWorkspaceExpanded('w2', true);
      await ui.setWorkspaceExpanded('w1', true);
      expect(ui.drawerExpandedOf('w1'), isTrue);
      expect(ui.drawerExpandedOf('w2'), isTrue);

      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(again.drawerExpandedOf('w1'), isTrue);
      expect(again.drawerExpandedOf('w2'), isTrue);
    });

    test('页签：按会话懒读 + 写后读回（存 id 不是下标）', () async {
      expect(await ui.viewOf('sid-1'), isNull);
      await ui.setView('sid-1', 'trajectory');
      expect(prefs.values['${UiKey.sessionViewPrefix}sid-1'], 'trajectory');
      expect(await ui.viewOf('sid-1'), 'trajectory');

      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(await again.viewOf('sid-1'), 'trajectory');
      expect(await again.viewOf('sid-2'), isNull, reason: '别的会话不该跟着有值');
    });

    test('换电脑：clearHostScope 删光 host.*，device.* 一个不动', () async {
      await ui.setThemeMode('light');
      await ui.setUiScaleIndex(3);
      await ui.setLastSession('sid-1');
      await ui.setWorkspaceExpanded('w1', false);
      await ui.setView('sid-1', 'trajectory');

      await ui.clearHostScope();

      expect(
        prefs.values.keys.where((k) => k.startsWith(UiKey.hostPrefix)),
        isEmpty,
      );
      expect(ui.themeMode, 'light');
      expect(ui.uiScaleIndex, 3);
      expect(ui.lastSession, isNull);
      expect(ui.drawerExpandedOf('w1'), isNull);
      expect(await ui.viewOf('sid-1'), isNull);
    });

    test('pruneSessions：只删已消失会话的页签', () async {
      await ui.setView('sid-1', 'trajectory');
      await ui.setView('sid-2', 'chat');
      await ui.pruneSessions({'sid-1'});
      expect(
        prefs.values.containsKey('${UiKey.sessionViewPrefix}sid-2'),
        isFalse,
      );
      expect(prefs.values['${UiKey.sessionViewPrefix}sid-1'], 'trajectory');
    });

    test('提问进度：按会话存取，null 等于删', () async {
      expect(await ui.questionDraftOf('sid-1'), isNull);
      await ui.setQuestionDraft('sid-1', '{"item":"t:1"}');
      expect(await ui.questionDraftOf('sid-1'), '{"item":"t:1"}');
      expect(prefs.values[UiKey.questionDraft('sid-1')], '{"item":"t:1"}');

      await ui.setQuestionDraft('sid-1', null);
      expect(await ui.questionDraftOf('sid-1'), isNull);
      expect(prefs.values.containsKey(UiKey.questionDraft('sid-1')), isFalse);
    });

    test('pruneSessions 也清掉已消失会话的提问进度', () async {
      await ui.setQuestionDraft('sid-1', '{"item":"t:1"}');
      await ui.setQuestionDraft('sid-2', '{"item":"t:2"}');
      await ui.pruneSessions({'sid-1'});
      expect(prefs.values.containsKey(UiKey.questionDraft('sid-2')), isFalse);
      expect(prefs.values.containsKey(UiKey.questionDraft('sid-1')), isTrue);
    });

    test('pruneWorkspaces：只留还活着的工作区', () async {
      await ui.setWorkspaceExpanded('w1', false);
      await ui.setWorkspaceExpanded('w2', false);
      await ui.pruneWorkspaces({'w1'});
      expect(ui.drawerExpandedOf('w1'), isFalse);
      expect(ui.drawerExpandedOf('w2'), isNull);
    });
  });

  group('按电脑分桶（host.<hostId>.*）', () {
    test('A 的 host.* 在 B 上看不到；切回 A 还在（不删）', () async {
      final onA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await onA.open();
      await onA.setLastSession('sid-a');
      await onA.setWorkspaceExpanded('w1', false);
      await onA.setView('sid-a', 'trajectory');
      await onA.setSessionDraft('sid-a', '写到一半');

      expect(prefs.values['host.pc-A.last_session'], 'sid-a');
      expect(
        prefs.values['host.pc-A.session_draft.sid-a'],
        contains('写到一半'),
        reason: '键的形状是 host.<hostId>.<field>',
      );

      final onB = UiStateStore(prefs: prefs, hostId: 'pc-B');
      await onB.open();
      expect(onB.lastSession, isNull, reason: 'B 不该看到 A 的落点');
      expect(onB.drawerExpandedOf('w1'), isNull);
      expect(await onB.viewOf('sid-a'), isNull);
      expect(await onB.sessionDraftOf('sid-a'), isNull);

      final backToA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await backToA.open();
      expect(backToA.lastSession, 'sid-a');
      expect(backToA.drawerExpandedOf('w1'), isFalse);
      expect(await backToA.viewOf('sid-a'), 'trajectory');
      expect(await backToA.sessionDraftOf('sid-a'), '写到一半');
    });

    test('pruneSessions 只剪当前桶：B 的清单不清掉 A 的页签/草稿', () async {
      final onA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await onA.open();
      await onA.setView('sid-1', 'trajectory');
      await onA.setSessionDraft('sid-1', 'A 的草稿');
      await onA.setQuestionDraft('sid-1', '{"item":"t:1"}');

      final onB = UiStateStore(prefs: prefs, hostId: 'pc-B');
      await onB.open();
      await onB.setView('sid-1', 'chat');
      // B 的清单里没有 sid-1（两台电脑的 sid 各自独立）。
      await onB.pruneSessions(<String>{'sid-b-other'});

      expect(prefs.values['host.pc-B.session_view.sid-1'], isNull);
      expect(
        prefs.values['host.pc-A.session_view.sid-1'],
        'trajectory',
        reason: '拿 B 的清单剪 A 的桶 = 把"切走"变成"删掉"',
      );
      expect(prefs.values['host.pc-A.session_draft.sid-1'], contains('A 的草稿'));
      expect(prefs.values['host.pc-A.question_draft.sid-1'], '{"item":"t:1"}');

      final backToA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await backToA.open();
      expect(await backToA.viewOf('sid-1'), 'trajectory');
      expect(await backToA.sessionDraftOf('sid-1'), 'A 的草稿');
    });

    test('不做旧数据兼容：平铺键不会被搬进桶，也不被删', () async {
      // 协议没发版、没有存量安装 —— 平铺键是"状态不属于任何一台电脑"那一档，
      // 拿到身份之后**不会**被当成需要迁移的旧数据（少一条会漂的双形状）。
      prefs.values[UiKey.lastSession] = 'sid-1';
      prefs.values[UiKey.drawerExpansion] = '{"w1":false}';
      final writesBefore = prefs.writes;

      final onA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await onA.open();

      expect(onA.lastSession, isNull, reason: '桶里没有就是没有，不从平铺键补');
      expect(prefs.writes, writesBefore, reason: 'open() 不写盘（没有迁移步骤）');
      expect(prefs.values[UiKey.lastSession], 'sid-1', reason: '不认识的键不删');
      expect(prefs.values.containsKey('host.pc-A.last_session'), isFalse);
    });

    test('clearHostScope 只删当前桶，别的电脑的桶不动', () async {
      final onA = UiStateStore(prefs: prefs, hostId: 'pc-A');
      await onA.open();
      await onA.setLastSession('sid-a');
      await onA.setView('sid-a', 'trajectory');

      final onB = UiStateStore(prefs: prefs, hostId: 'pc-B');
      await onB.open();
      await onB.setLastSession('sid-b');

      await onA.clearHostScope();

      expect(onA.lastSession, isNull);
      expect(await onA.viewOf('sid-a'), isNull);
      expect(
        prefs.values.keys.where((k) => k.startsWith('host.pc-A.')),
        isEmpty,
      );
      expect(
        prefs.values['host.pc-B.last_session'],
        'sid-b',
        reason: '忘掉这一台不等于撤销所有配对',
      );
    });
  });

  group('草稿：按会话、旁路写、防抖', () {
    test('写进去的是 JSON（形状照 DraftSnapshot），读回来是正文', () async {
      await ui.setSessionDraft('sid-1', '你好');
      expect(
        prefs.values[UiKey.sessionDraft('sid-1')],
        '{"text":"你好","references":[]}',
        reason: '形状照桌面 `DraftSnapshot`：今天只有 text，但盘上格式不换',
      );
      expect(await ui.sessionDraftOf('sid-1'), '你好');
      expect(await ui.sessionDraftOf('sid-2'), isNull);
    });

    test('盘上是旧形态（纯字符串）也认（迁移友好）', () async {
      prefs.values[UiKey.sessionDraft('sid-1')] = '旧草稿';
      expect(await ui.sessionDraftOf('sid-1'), '旧草稿');
    });

    test('盘上坏了 → 当没有（不抛）', () async {
      prefs.values[UiKey.sessionDraft('sid-1')] = '{不是 json';
      expect(await ui.sessionDraftOf('sid-1'), isNull);
    });

    test('防抖：连打三次只落一次盘；flush 立刻落', () async {
      final before = prefs.writes;
      ui.noteDraft('sid-1', '你');
      ui.noteDraft('sid-1', '你好');
      ui.noteDraft('sid-1', '你好啊');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(prefs.writes, before, reason: '20ms 内不该写盘（防抖窗口 300ms）');

      await ui.flushDrafts();
      expect(prefs.writes, before + 1, reason: '三次击键合并成一次写');
      expect(await ui.sessionDraftOf('sid-1'), '你好啊');
    });

    test('切会话前 flush 能把在途草稿写下去（不丢最后几个字）', () async {
      ui.noteDraft('sid-1', '写到一半');
      await ui.flushDrafts();
      final again = UiStateStore(prefs: prefs);
      await again.open();
      expect(await again.sessionDraftOf('sid-1'), '写到一半');
    });

    test('空草稿等于删掉（别在盘上留空串）', () async {
      await ui.setSessionDraft('sid-1', '有内容');
      await ui.setSessionDraft('sid-1', '');
      expect(prefs.values.containsKey(UiKey.sessionDraft('sid-1')), isFalse);
    });
  });

  test('open 只读一次（不是每键/每帧一趟）', () async {
    prefs.values[UiKey.themeMode] = 'dark';
    prefs.values[UiKey.lastSession] = 'sid-1';
    prefs.values['${UiKey.sessionViewPrefix}sid-1'] = 'chat';
    final again = UiStateStore(prefs: prefs);
    await again.open();
    // 启动只读固定那几个键；会话级页签是懒读，不在 open 里。
    expect(again.themeMode, 'dark');
    expect(again.lastSession, 'sid-1');
    expect(await again.viewOf('sid-1'), 'chat');
  });
}
