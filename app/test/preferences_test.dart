/// 手机本地偏好的回归（`model/preferences.dart` + `AppModel` 的落盘/恢复）。
///
/// ## 为什么单独一组
///
/// DSH 把"工作步骤展示 / 性能与用量"这些偏好存在**电脑上**（Host
/// user-settings，`docs/settings-porting-notes.md` §7.1 逐条列了出处），
/// 为的是跨浏览器跟随。手机端**改存本地**是有意偏离：这些偏好只影响这台
/// 手机的呈现，下发到电脑既无意义也会互相覆盖。
///
/// 这一组钉三件事：盘上值↔枚举双向、重启后恢复、怪值保持默认（不猜）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/model/preferences.dart';
import 'package:flutter_test/flutter_test.dart';

class _PrefClient implements SyncClient {
  final _jobs = StreamController<JobFrame>.broadcast();

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
  Future<void> subscribe(String sid, {required int since}) async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw UnimplementedError();
}

void main() {
  test('线值 ↔ 枚举双向；怪值返回 null（调用方保持默认）', () {
    expect(TranscriptView.fromWire('fully-open'), TranscriptView.fullyOpen);
    expect(TranscriptView.fullyOpen.wire, 'fully-open');
    expect(TranscriptView.fromWire('nonsense'), isNull);
    expect(TranscriptView.fromWire(null), isNull);
    expect(PerformanceUsage.fromWire('compact'), PerformanceUsage.compact);
    expect(PerformanceUsage.detailed.wire, 'detailed');
    expect(PerformanceUsage.fromWire(''), isNull);
  });

  test('落盘 + 重启恢复（同一个 meta 表）', () async {
    final store = _FakePrefs();
    final app = AppModel(client: _PrefClient(), prefs: store);
    await app.start();
    expect(app.transcriptView, TranscriptView.standard, reason: '默认标准');

    await app.setTranscriptView(TranscriptView.fullyOpen);
    await app.setPerformanceUsage(PerformanceUsage.compact);
    expect(app.transcriptView, TranscriptView.fullyOpen);

    // 重启：新 AppModel 读同一个 store。
    final revived = AppModel(client: _PrefClient(), prefs: store);
    await revived.start();
    expect(
      revived.transcriptView,
      TranscriptView.fullyOpen,
      reason: '重启后还是用户选的那个',
    );
    expect(revived.performanceUsage, PerformanceUsage.compact);
    app.dispose();
    revived.dispose();
  });

  test('盘上是怪值：保持默认，不猜', () async {
    final store = _FakePrefs({
      'transcript_view': 'garbage',
      'performance_usage': 'detailed-ish',
    });
    final app = AppModel(client: _PrefClient(), prefs: store);
    await app.start();
    expect(app.transcriptView, TranscriptView.standard);
    expect(app.performanceUsage, PerformanceUsage.detailed);
    app.dispose();
  });

  test('同一个值重复切：不写盘', () async {
    final store = _FakePrefs();
    final app = AppModel(client: _PrefClient(), prefs: store);
    await app.start();
    await app.setTranscriptView(TranscriptView.standard); // 就是默认值
    expect(store.writes, isEmpty, reason: '空操作不该落盘');
    app.dispose();
  });
}

/// 内存版的偏好缝（形状同 `MetaPreferences` 包的窄接口）。
class _FakePrefs implements PreferenceStore {
  _FakePrefs([Map<String, Object?> initial = const {}])
    : rows = Map<String, Object?>.of(initial);

  final Map<String, Object?> rows;
  final List<String> writes = [];

  @override
  Future<String?> read(String key) async => rows[key] as String?;

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    rows[key] = value;
  }
}
