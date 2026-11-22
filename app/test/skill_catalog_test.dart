/// 技能目录（`skill.catalog`）的数据面：**归属按会话**、能力位缺席就不发。
///
/// 桌面 `/` 菜单是"命令表 + 这一会话的技能目录"两段拼起来的
/// （`ui-skill/src/client/index.ts:171-184`）。这一组守三件事：
///
/// 1. **读到就落进 `slashSkills`**，形状由 `model/skill.dart` 解；
/// 2. **换会话时不许摆上一个会话的技能**（`_skillsSid` 的归属判据，与投影同一条）——
///    否则菜单里会出现"别的项目才有的技能"，点了就是一条发不出去的命令；
/// 3. **`caps.skills` 为假就不发请求**：没装 skill 服务的部署里连接器根本不挂这个方法，
///    发出去只会拿 `connector/unsupported` 而被画成"技能读取失败"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

typedef _Handler =
    Future<Object?> Function(String method, Map<String, Object?> params);

class _Client extends FakeSyncClient {
  _Client({required this.onCall});

  final _Handler onCall;
  final List<String> methods = <String>[];
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
  }) async {
    methods.add(method);
    return await onCall(method, params) as T;
  }
}

List<Object?> _rows() => <Object?>[
  <String, Object?>{
    'name': 'write-ppt',
    'description': '做 PPT',
    'modelInvocable': true,
  },
  <String, Object?>{
    'name': 'quiet',
    'description': '',
    'modelInvocable': false,
  },
];

void main() {
  test('读到就落进 slashSkills；空说明不带、modelInvocable 解析出来', () async {
    final app = AppModel(
      client: _Client(
        onCall: (m, p) async => m == 'skill.catalog'
            ? <String, Object?>{'skills': _rows()}
            : m == 'repo.info'
            ? <String, Object?>{
                'caps': <String, Object?>{'skills': true},
              }
            : null,
      ),
    );
    addTearDown(app.dispose);
    await app.refreshRepoInfo();
    await app.openSession('sid_A');
    await app.refreshSkillCatalog('sid_A');

    final skills = app.slashSkills;
    expect(skills.map((s) => s.name).toList(), ['write-ppt', 'quiet']);
    expect(skills.first.description, '做 PPT');
    expect(skills[1].description, isNull, reason: '空说明视同没给，不编一句');
    expect(skills[1].modelInvocable, isFalse);
  });

  test('换会话：上一个会话的技能不许摆出来（归属判据）', () async {
    // B 的目录读取**卡住**：这正是"新包还没落地"的那一帧。
    final gate = Completer<void>();
    final app = AppModel(
      client: _Client(
        onCall: (m, p) async {
          if (m == 'repo.info') {
            return <String, Object?>{
              'caps': <String, Object?>{'skills': true},
            };
          }
          if (m != 'skill.catalog') return null;
          if (p['sid'] == 'sid_B') await gate.future;
          return <String, Object?>{'skills': _rows()};
        },
      ),
    );
    addTearDown(app.dispose);
    await app.refreshRepoInfo();
    await app.openSession('sid_A');
    await app.refreshSkillCatalog('sid_A');
    expect(app.slashSkills, isNotEmpty);

    // 换到 B：B 的目录还没读到 ⇒ 空（不是继续显示 A 的）。
    final opening = app.openSession('sid_B');
    await Future<void>.delayed(Duration.zero);
    expect(
      app.slashSkills,
      isEmpty,
      reason: '按 `_skillsSid` 判归属：菜单里出现别的会话的技能就是点了也发不出去',
    );

    gate.complete();
    await opening;
  });

  test('能力位为假：一次请求都不发（缺服务不能被画成故障）', () async {
    final client = _Client(
      onCall: (m, p) async => m == 'repo.info'
          ? <String, Object?>{'caps': <String, Object?>{}}
          : null,
    );
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.refreshRepoInfo();
    await app.refreshSkillCatalog('sid_A');

    expect(
      client.methods.where((m) => m == 'skill.catalog'),
      isEmpty,
      reason: '`caps.skills` 为假时连接器不挂这个方法，发出去只会拿 unsupported',
    );
    expect(app.slashSkills, isEmpty);
  });
}
