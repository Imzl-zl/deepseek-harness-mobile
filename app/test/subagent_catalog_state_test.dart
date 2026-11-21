/// 子智能体目录的**状态机**回归（2026-11-21 真机：面板一直转圈）。
///
/// ## 钉住的三条不变量
///
/// 1. **没读过 ⇒ `never`，不是 `loading`**：给 `loading` 等于声称"有一条读取在飞"，
///    界面上于是只有一个永远转的圈，而手里没有一处事实能回答"到底有没有人在读"。
/// 2. **`notModified` 只在"手里真有这一包"时成立**：摘要可以在一次失败之后
///    活下来（服务端记的是"你上次应用过的那份"），那时再答"没变"就意味着
///    **正文永远拿不回来** —— 所以必须落成 `error`（界面上有「重试」），
///    不能停在 `loading`（界面上只有转圈）。
/// 3. **失败保留上一次的内容**：清空会把"曾经读到过"改写成"从没读到过"，
///    而摘要还在服务端 —— 下一次带摘要的读取得到"没变"，这一屏就死在那里。
/// 4. **在飞键是 `(key, sid)`**：A 会话的读取在飞时，B 会话的读取必须真的发出。
///    原来只按 key 合流，B 拿到的是 A 那一次的 future，B 的请求根本没发。
///
/// 判据在 `data/subagent_catalog_cache.dart`（迁移唯一一处）与
/// `data/host_state.dart` 的 `inFlightToken`。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/host_state.dart';
import 'package:dsh_mobile/model/subagent.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

typedef _Handler =
    Future<Object?> Function(String method, Map<String, Object?> params);

class _Client extends FakeSyncClient {
  _Client({required this.onCall});

  final _Handler onCall;
  final StreamController<JobFrame> _jobs =
      StreamController<JobFrame>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => await onCall(method, params) as T;
}

/// 一行目录（线上形状：`{id, createdAt, mode}`，`mode` 只有两档）。
List<Object?> _catalogRow({
  String id = 'child-1',
  String mode = 'continuable',
}) => <Object?>[
  <String, Object?>{'id': id, 'createdAt': 1, 'mode': mode},
];

void main() {
  test('没读过的会话是 never —— 不是"正在加载"，也没有读取在飞', () async {
    final app = AppModel(client: _Client(onCall: (m, p) async => null));
    await app.start();

    final catalog = app.subagentCatalogOf('sid_A');
    expect(catalog.state, SubagentCatalogState.never);
    expect(catalog.isUnread, isTrue);
    // **这两条必须在旧代码上红**：原来没读过返回 `loading`，
    // `isLoadingEmpty` 于是为真 —— 界面上一句「正在加载」对着零个在飞请求。
    expect(catalog.isLoadingEmpty, isFalse, reason: '没有读取在飞，就不该画转圈');
    expect(catalog.isKnownLeaf, isFalse, reason: '没读过不是"它没有下级"的证据');
    app.dispose();
  });

  test('宿主答"没变"但手里没有这一包：落 error（不是永远停在 loading）', () async {
    final app = AppModel(
      client: _Client(
        onCall: (m, p) async => m == 'session.projections'
            ? <String, Object?>{'notModified': true}
            : null,
      ),
    );
    await app.start();
    await app.refreshSubagentCatalog('sid_A');

    final catalog = app.subagentCatalogOf('sid_A');
    expect(
      catalog.state,
      SubagentCatalogState.error,
      reason: '停在 loading 的话界面上只有转圈，连重试入口都没有（2026-11-21 真机）',
    );
    expect(catalog.isLoadingEmpty, isFalse);
    expect(app.lastError, isNotNull, reason: '这种"摘要比内容活得久"必须留声');
    app.dispose();
  });

  test('读到过之后一次失败：内容留着，状态仍是 ready', () async {
    var fail = false;
    final app = AppModel(
      client: _Client(
        onCall: (m, p) async {
          if (m != 'session.projections') return null;
          if (fail) {
            throw const ProtocolException(ErrorCode.internal, 'boom');
          }
          return <String, Object?>{'subagentCatalog': _catalogRow()};
        },
      ),
    );
    await app.start();
    await app.refreshSubagentCatalog('sid_A');
    expect(app.subagentCatalogOf('sid_A').entries, hasLength(1));

    fail = true;
    await app.refreshSubagentCatalog('sid_A');

    final catalog = app.subagentCatalogOf('sid_A');
    expect(
      catalog.state,
      SubagentCatalogState.ready,
      reason: '清成 error 等于把"读到过"改写成"从没读到过"，而摘要还在电脑侧',
    );
    expect(catalog.entries.map((r) => r.id).toList(), ['child-1']);
    expect(app.lastError, isNotNull, reason: '失败本身仍然要留声');
    app.dispose();
  });

  test('A 会话的读取在飞时，B 会话的读取必须真的发出', () async {
    final gate = Completer<void>();
    final seen = <String>[];
    final app = AppModel(
      client: _Client(
        onCall: (m, p) async {
          if (m != 'session.projections') return null;
          final sid = p['sid']! as String;
          seen.add(sid);
          if (sid == 'sid_A') await gate.future;
          return <String, Object?>{'subagentCatalog': <Object?>[]};
        },
      ),
    );
    await app.start();

    // A：开会话时那一次投影读取，卡住不返回。
    final opening = app.openSession('sid_A');
    await Future<void>.delayed(Duration.zero);
    expect(seen, contains('sid_A'));

    // B：面板被看见 ⇒ 登记表的 `panelVisible` 列要发一次 B 的读取。
    final focused = app.focusView(
      'sid_B',
      trigger: HostStateTrigger.panelVisible,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      seen,
      contains('sid_B'),
      reason: '在飞键只按 key 的话，B 会合流到 A 那一次，B 的请求根本不发 —— 面板于是永久转圈',
    );

    gate.complete();
    await opening;
    await focused;
    app.dispose();
  });

  test('登记录里 `panelVisible` 只挂会话级投影那一列', () {
    final entry = hostStateRegistry
        .where((e) => e.key == HostStateKey.sessionProjections)
        .toList();
    expect(entry, hasLength(1));
    expect(entry.single.triggers, contains(HostStateTrigger.panelVisible));
    // 宿主级 key 不该被"面板被看见"带起来（那是替宿主做决定）。
    for (final other in hostStateRegistry) {
      if (other.key == HostStateKey.sessionProjections) continue;
      expect(
        other.triggers,
        isNot(contains(HostStateTrigger.panelVisible)),
        reason: '${other.key} 没有"面板"这个概念',
      );
    }
  });
}
