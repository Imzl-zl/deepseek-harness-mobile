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

    test('pruneWorkspaces：只留还活着的工作区', () async {
      await ui.setWorkspaceExpanded('w1', false);
      await ui.setWorkspaceExpanded('w2', false);
      await ui.pruneWorkspaces({'w1'});
      expect(ui.drawerExpandedOf('w1'), isFalse);
      expect(ui.drawerExpandedOf('w2'), isNull);
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
