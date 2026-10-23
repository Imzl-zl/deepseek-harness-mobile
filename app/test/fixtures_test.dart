/// 跑 `protocol/fixtures`（15 条）—— 与电脑侧同一批场景脚本。
///
/// **条数是三处同步的**：`protocol/fixtures/` 的文件数、`protocol/verify-fixtures.mjs`、
/// `connector/tests/fixtures.test.ts` 的 `REFERENCE_CHECK_COUNT`、以及这里的 `files.length` 断言。
/// 删/加一条 fixture 必须三处一起改（`fce4f9e` 删 fixture 16 时这里漏了，`flutter test`
/// 因此红了一整轮）。
///
/// 这是 `protocol/verify-fixtures.mjs` 在 Dart 手机侧的对应物，判据逐条对齐：
/// 形状校验 → 三角色回放（手机 ⇄ 中转 ⇄ 桥接）→ 全局不变量 → 逐条期望。
///
/// ## 角色划分
///
/// - **手机** ← `lib/core/`（**产品代码**：`DeviceSession`）；
/// - **中转** ← `test/support/fake_roles.dart` 的 `FakeRelay`（手机端不实现中转）；
/// - **桥接** ← 同文件的 `FakeBridge`（手机端不实现电脑侧）。
///
/// 与 `connector/tests/fixtures.test.ts` 正好互补：那边把手机侧做成替身。
/// **两侧跑同一批 fixtures**，所以任何一侧的语义漂移都会被其中一侧抓住。
///
/// ## 本层测什么、不测什么
///
/// 只测**会话层**语义（恢复判定、分页拼接、幂等去重、空洞、待审批重建、`live` 不入账）。
/// 连接层（握手、`fc` 计数器、nonce、流控、重放拒绝）不在这里 —— 它由
/// `protocol/vectors` 的已知答案向量（`crypto_vectors_test.dart`）覆盖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_roles.dart';

/// 从当前目录往上找到仓库根（含 `protocol/fixtures` 的那一层）。
///
/// **不硬编码盘符**：仓库从 `C:\sudy` 搬到 `D:\sudy` 时，11 个写死路径的脚本
/// 静默全红过（见 `tools.md` 的 Pitfalls）。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i += 1) {
    if (Directory('${dir.path}/protocol/fixtures').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    '找不到仓库根（含 protocol/fixtures 的那一层），当前目录 ${Directory.current.path}',
  );
}

/// fixtures 里出现过的步骤（17 种）与期望键（14 种）。
///
/// **写死在这里是有意的**：它们是"规格的封闭清单"，多一个少一个都该有人看一眼。
/// 从文件里现算的话，漏实现一个 `op` 只会表现为"这条 fixture 恰好没走到它"。
const Set<String> knownOps = <String>{
  'append',
  'redeliver',
  'hello',
  'ack',
  'ackSeq',
  'snapshotPage',
  'relayEvictAll',
  'relayRestart',
  'bridgeTrim',
  'bridgeRestart',
  'sendTwice',
  'setTransient',
  'ask',
  'answer',
  'rebuildPending',
  'live',
  'takeover',
};

const Set<String> knownExpectKeys = <String>{
  'recovery',
  'items',
  'itemCount',
  'bridgeItemCount',
  'deviceCursor',
  'requests',
  'transient',
  'pending',
  'duplicates',
  'gaps',
  'liveIgnored',
  'takeover',
  'converged',
  'relayRoutingKeysOnly',
};

const Set<String> knownOutcomes = <String>{'delta', 'snapshot'};
const Set<String> knownReasons = <String>{
  'window-missed',
  'revision-newer',
  'history-rewritten',
  'no-session',
};
const Set<String> knownSources = <String>{'bridge', 'relay'};

void main() {
  test('15 条 fixtures 在手机侧跑绿（三角色回放：手机 ⇄ 中转 ⇄ 桥接）', () {
    final failures = <String>[];
    var checks = 0;

    void check(bool ok, String label, [String? detail]) {
      checks += 1;
      if (!ok) failures.add(detail == null ? label : '$label → $detail');
    }

    void validateShape(String file, Map<String, Object?> fx) {
      for (final key in const [
        'name',
        'why',
        'bridge',
        'relay',
        'device',
        'steps',
        'expect',
      ]) {
        check(fx.containsKey(key), '$file: 缺少字段 $key');
      }
      final steps = fx['steps'];
      if (steps is! List || steps.isEmpty) check(false, '$file: steps 必须是非空数组');
      for (final (index, step)
          in ((steps as List?) ?? const <Object?>[])
              .cast<Map<String, Object?>>()
              .indexed) {
        check(
          knownOps.contains(step['op']),
          '$file: 第 ${index + 1} 步的 op 未知',
          '${step['op']}',
        );
      }
      final recovery = (fx['expect'] as Map<String, Object?>?)?['recovery'];
      if (recovery is Map) {
        for (final entry in recovery.entries) {
          final list = entry.value is List
              ? entry.value as List
              : <Object?>[entry.value];
          check(list.isNotEmpty, '$file: ${entry.key} 的恢复期望为空');
          for (final want in list.cast<Map<String, Object?>>()) {
            check(
              knownOutcomes.contains(want['outcome']),
              '$file: ${entry.key} 的 outcome 非法',
              '${want['outcome']}',
            );
            check(
              knownSources.contains(want['source']),
              '$file: ${entry.key} 的 source 非法',
              '${want['source']}',
            );
            if (want['outcome'] == 'snapshot') {
              if (want['reason'] != null) {
                check(
                  knownReasons.contains(want['reason']),
                  '$file: ${entry.key} 的 reason 非法',
                  '${want['reason']}',
                );
              }
            } else {
              check(
                want['from'] is int && want['to'] is int,
                '$file: ${entry.key} 的增量必须带 from/to',
              );
            }
          }
        }
      }
    }

    void runFixture(String file, Map<String, Object?> fx) {
      final bridgeSeed = <String, Map<String, String>>{};
      final deviceSeed = <String, Map<String, String>>{};
      final deviceSince = <String, int>{};

      final deviceConfig = fx['device'] as Map<String, Object?>?;
      if (deviceConfig?['since'] is Map) {
        for (final entry in (deviceConfig!['since'] as Map).entries) {
          deviceSince['${entry.key}'] = (entry.value as num).toInt();
        }
      }
      if (deviceConfig?['items'] is Map) {
        for (final entry in (deviceConfig!['items'] as Map).entries) {
          final items = <String, String>{};
          for (final item in (entry.value as Map).entries) {
            items['${item.key}'] = '${item.value}';
          }
          deviceSeed['${entry.key}'] = items;
        }
      }

      final bridge = FakeBridge(
        initial: bridgeSeed,
        snapshotPageSize: ((fx['snapshotPageSize'] as num?)?.toInt()) ?? 100,
      );
      // `relay` 会被 `relayRestart` 换成一个新的（模拟中转状态清空后重启），所以不是 final。
      var relay = FakeRelay(
        ((fx['relay'] as Map<String, Object?>?)?['windowSize'] as num?)
                ?.toInt() ??
            1000,
      );
      final device = DeviceSession(since: deviceSince, items: deviceSeed);

      final requests = <String, int>{};
      final takeovers = <Map<String, Object?>>[];
      var liveReceived = 0;
      final liveSeqBefore = <String, int?>{};

      RecoveryAnswer recovery(String sid) {
        final since = device.sinceOf(sid);
        final latest = bridge.latestSeq(sid);
        final transientNow = bridge.transientOf(sid);

        if (latest == null) {
          return RecoveryAnswer(
            sid: sid,
            source: 'bridge',
            outcome: RecoveryOutcome.snapshot,
            reason: SnapshotReason.noSession,
            asOfSeq: since,
            hasMore: false,
            items: const <ItemRecord>[],
            to: since,
            transient: transientNow,
          );
        }
        if (since > latest) {
          return bridge.hello(sid, since);
        }
        final from = since + 1;
        if (from <= latest) {
          final served = relay.since(sid, since);
          if (served != null) {
            // 中转给的是不透明帧，解封发生在手机侧（fixtures 词汇层的 seal 是可逆占位）。
            return RecoveryAnswer(
              sid: sid,
              source: 'relay',
              outcome: RecoveryOutcome.delta,
              from: from,
              to: latest,
              items: served.map((frame) {
                final body = jsonDecode(frame.box) as Map<String, Object?>;
                return ItemRecord(
                  itemId: '${body['itemId']}',
                  text: '${body['text']}',
                  seq: frame.seq,
                );
              }).toList(),
              transient: transientNow,
            );
          }
        }
        return bridge.hello(sid, since);
      }

      final steps = (fx['steps'] as List).cast<Map<String, Object?>>();
      for (final step in steps) {
        switch (step['op']) {
          case 'append':
            relay.put(
              bridge.append(
                '${step['sid']}',
                '${step['itemId']}',
                '${step['text']}',
              ),
            );
          case 'redeliver':
            final frame = bridge.frameAt(
              '${step['sid']}',
              (step['seq'] as num).toInt(),
            );
            // 重复/并发投递：分页期间只缓存，否则按 upsert 落盘。
            device.receive(frame.sid, frame.itemId, frame.text, frame.seq);
          case 'hello':
            final sid = step['sid'];
            final sids = sid != null
                ? <String>['$sid']
                : deviceSince.keys.toList();
            for (final one in sids) {
              device.applyAnswer(recovery(one));
            }
          case 'snapshotPage':
            device.applyAnswer(bridge.snapshotPage('${step['sid']}'));
          case 'ack':
            device.commit(
              '${step['sid']}',
              device.received['${step['sid']}'] ?? 0,
            );
          case 'ackSeq':
            device.commit('${step['sid']}', (step['seq'] as num).toInt());
          case 'relayEvictAll':
            relay.evictAll();
          case 'relayRestart':
            relay = FakeRelay(
              ((fx['relay'] as Map<String, Object?>?)?['windowSize'] as num?)
                      ?.toInt() ??
                  1000,
            );
          case 'bridgeTrim':
            bridge.trim('${step['sid']}', (step['upto'] as num).toInt());
          case 'bridgeRestart':
            bridge.restart(keepDedupe: step['keepDedupe'] != false);
          case 'sendTwice':
            for (var i = 0; i < 2; i += 1) {
              final requestId = '${step['requestId']}';
              final frame = bridge.send(
                '${step['sid']}',
                requestId,
                '${step['text']}',
              );
              requests[requestId] =
                  (requests[requestId] ?? 0) + (frame == null ? 0 : 1);
              if (frame != null) relay.put(frame);
            }
          case 'setTransient':
            bridge.setTransient('${step['sid']}', <String, Object?>{
              if (step['pendingApprovals'] != null)
                'pendingApprovals': step['pendingApprovals'],
              if (step['computerOnline'] != null)
                'computerOnline': step['computerOnline'],
            });
          case 'ask':
            relay.put(
              bridge.ask(
                '${step['sid']}',
                '${step['callId']}',
                step['payload'] ?? <String, Object?>{},
              ),
            );
          case 'answer':
            relay.put(
              bridge.answer(
                '${step['sid']}',
                '${step['callId']}',
                step['decision'],
              ),
            );
          case 'rebuildPending':
            bridge.rebuildPending();
          case 'live':
            // live 帧只交给渲染层：不进 items、不动游标、不改修订号（契约 §3）。
            liveReceived += 1;
            liveSeqBefore['${step['sid']}'] = bridge.latestSeq(
              '${step['sid']}',
            );
          case 'takeover':
            takeovers.add(<String, Object?>{
              'sid': step['sid'],
              // 手机侧不实现仲裁（那是电脑侧的判定），但 fixtures 要求这一列被回放，
              // 所以这里只记录输入，断言交给 `expect.takeover` 的形状校验。
              'mode': step['mode'],
              'deviceCount': (step['devices'] as List?)?.length ?? 0,
            });
          default:
            throw StateError('未实现的步骤: ${step['op']}');
        }
      }

      final routingKeysSeen = relay.routingKeysSeen;
      final expect =
          (fx['expect'] as Map<String, Object?>?) ?? const <String, Object?>{};

      // 形状校验：未知的期望键要吵 —— 它意味着 fixtures 长出了新面而我们没实现。
      for (final key in expect.keys) {
        check(knownExpectKeys.contains(key), '$file: 未知的期望键 $key');
      }

      // ---- 全局规则：恢复只有两种结果；快照必带原因与 asOfSeq；瞬时事实永远来自电脑侧 ----
      for (final answer in device.answers) {
        check(
          knownOutcomes.contains(answer.outcome.name),
          '$file: ${answer.sid} 的恢复结果不是两种之一',
          answer.outcome.name,
        );
        if (answer.outcome == RecoveryOutcome.snapshot) {
          check(
            answer.reason != null &&
                knownReasons.contains(snapshotReasonWire[answer.reason]),
            '$file: ${answer.sid} 的快照原因非法',
            '${answer.reason}',
          );
          check(answer.asOfSeq is int, '$file: ${answer.sid} 的快照必须带 asOfSeq');
          check(answer.hasMore is bool, '$file: ${answer.sid} 的快照必须带 hasMore');
        }
        // **瞬时事实永远来自电脑侧**（不变量 I4）：中转只搬运帧，不合成事实。
        // 这条必须逐答断言 —— 少了它，"中转顺手编了个 computerOnline" 不会被任何东西发现。
        check(
          answer.transientSource == 'bridge',
          '$file: ${answer.sid} 的瞬时事实不是电脑侧给的',
          answer.transientSource,
        );
      }

      // ---- 逐条期望 ----
      final recoveryExpect = expect['recovery'];
      if (recoveryExpect is Map) {
        for (final entry in recoveryExpect.entries) {
          final sid = '${entry.key}';
          final list = entry.value is List
              ? (entry.value as List).cast<Map<String, Object?>>()
              : <Map<String, Object?>>[entry.value as Map<String, Object?>];
          final got = device.answers.where((a) => a.sid == sid).toList();
          check(
            got.length == list.length,
            '$file: $sid 恢复应答次数',
            '期望 ${list.length} 次，实际 ${got.length} 次',
          );
          for (
            var index = 0;
            index < list.length && index < got.length;
            index += 1
          ) {
            final want = list[index];
            final answer = got[index];
            // 期望里写了什么就断言什么（from/to/reason/asOfSeq/hasMore 一视同仁）。
            for (final field in want.entries) {
              if (field.key == 'items') continue;
              final actual = switch (field.key) {
                'outcome' => answer.outcome.name,
                'source' => answer.source,
                'reason' =>
                  answer.reason == null
                      ? null
                      : snapshotReasonWire[answer.reason],
                'from' => answer.from,
                'to' => answer.to,
                'asOfSeq' => answer.asOfSeq,
                'hasMore' => answer.hasMore,
                _ => null,
              };
              check(
                actual == field.value,
                '$file: $sid 第 ${index + 1} 次 ${field.key}',
                '期望 ${field.value}，实际 $actual',
              );
            }
            if (want['outcome'] == 'delta' && want['items'] != null) {
              check(
                answer.items.length == want['items'],
                '$file: $sid 第 ${index + 1} 次增量条目数',
                '期望 ${want['items']}，实际 ${answer.items.length}',
              );
            }
          }
        }
      }

      final itemsExpect = expect['items'];
      if (itemsExpect is Map) {
        for (final entry in itemsExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as List).map((e) => '$e').toList()..sort();
          final got = device.itemsOf(sid).keys.toList()..sort();
          check(
            _sameList(got, want),
            '$file: $sid 可见条目',
            '期望 ${want.join(',')}，实际 ${got.join(',')}',
          );
        }
      }

      final itemCountExpect = expect['itemCount'];
      if (itemCountExpect is Map) {
        for (final entry in itemCountExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            device.itemsOf(sid).length == want,
            '$file: $sid 条目数',
            '期望 $want，实际 ${device.itemsOf(sid).length}',
          );
        }
      }

      final bridgeItemCountExpect = expect['bridgeItemCount'];
      if (bridgeItemCountExpect is Map) {
        for (final entry in bridgeItemCountExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            bridge.itemsOf(sid).length == want,
            '$file: $sid 电脑侧条目数',
            '期望 $want，实际 ${bridge.itemsOf(sid).length}',
          );
        }
      }

      final deviceCursorExpect = expect['deviceCursor'];
      if (deviceCursorExpect is Map) {
        for (final entry in deviceCursorExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            device.sinceOf(sid) == want,
            '$file: $sid 已落盘游标',
            '期望 $want，实际 ${device.sinceOf(sid)}',
          );
        }
      }

      final requestsExpect = expect['requests'];
      if (requestsExpect is Map) {
        for (final entry in requestsExpect.entries) {
          final id = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            requests[id] == want,
            '$file: 幂等键 $id 生效次数',
            '期望 $want，实际 ${requests[id]}',
          );
        }
      }

      final transientExpect = expect['transient'];
      if (transientExpect is Map) {
        for (final entry in transientExpect.entries) {
          final sid = '${entry.key}';
          final got = device.transientOf(sid);
          for (final field in (entry.value as Map).entries) {
            check(
              got['${field.key}'] == field.value,
              '$file: $sid 瞬时事实 ${field.key}',
              '期望 ${field.value}，实际 ${got['${field.key}']}',
            );
          }
        }
      }

      final pendingExpect = expect['pending'];
      if (pendingExpect is Map) {
        for (final entry in pendingExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as List).map((e) => '$e').toList()..sort();
          final got = bridge.pendingOf(sid).keys.toList()..sort();
          check(
            _sameList(got, want),
            '$file: $sid 待审批集合',
            '期望 ${want.join(',')}，实际 ${got.join(',')}',
          );
        }
      }

      if (expect['takeover'] != null) {
        final want = expect['takeover'] is List
            ? (expect['takeover'] as List)
            : <Object?>[expect['takeover']];
        check(
          takeovers.length == want.length,
          '$file: 仲裁判定次数',
          '期望 ${want.length}，实际 ${takeovers.length}',
        );
      }

      if (expect['liveIgnored'] == true) {
        check(liveReceived > 0, '$file: 期望至少收到一帧 live');
        for (final entry in liveSeqBefore.entries) {
          final sid = entry.key;
          check(
            bridge.latestSeq(sid) == entry.value,
            '$file: $sid live 帧不得改变修订号',
            '之前 ${entry.value}，之后 ${bridge.latestSeq(sid)}',
          );
        }
        if (deviceCursorExpect is Map) {
          for (final entry in deviceCursorExpect.entries) {
            final sid = '${entry.key}';
            final want = (entry.value as num).toInt();
            check(
              device.sinceOf(sid) == want,
              '$file: $sid live 帧不得推进落盘水位',
              '期望 $want，实际 ${device.sinceOf(sid)}',
            );
          }
        }
      }

      final gapsExpect = expect['gaps'];
      if (gapsExpect is Map) {
        for (final entry in gapsExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            (device.gaps[sid] ?? 0) == want,
            '$file: $sid 空洞次数',
            '期望 $want，实际 ${device.gaps[sid] ?? 0}',
          );
        }
      }

      final duplicatesExpect = expect['duplicates'];
      if (duplicatesExpect is Map) {
        for (final entry in duplicatesExpect.entries) {
          final sid = '${entry.key}';
          final want = (entry.value as num).toInt();
          check(
            (device.duplicates[sid] ?? 0) == want,
            '$file: $sid 重复丢弃次数',
            '期望 $want，实际 ${device.duplicates[sid] ?? 0}',
          );
        }
      }

      if (expect['converged'] == true) {
        for (final sid in deviceSince.keys) {
          if (bridge.latestSeq(sid) == null) continue;
          check(
            device.convergedWith(sid, bridge.itemsOf(sid)),
            '$file: $sid 手机侧与电脑侧未收敛',
            '手机 ${device.itemsOf(sid)} / 电脑 ${bridge.itemsOf(sid)}',
          );
        }
      }

      if (expect['relayRoutingKeysOnly'] == true) {
        final clean = routingKeysSeen.every(
          (keys) => keys.every((k) => const ['t', 'sid', 'seq'].contains(k)),
        );
        check(clean, '$file: 中转的路由视图里出现了路由以外的字段', '$routingKeysSeen');
      }
    }

    // ---- 主流程 ----
    final dir = Directory('${_repoRoot().path}/protocol/fixtures');
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    check(files.isNotEmpty, 'protocol/fixtures 下没有 fixture');
    check(files.length == 15, 'fixture 条数', '期望 15，实际 ${files.length}');

    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final fx = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      validateShape(name, fx);
      try {
        runFixture(name, fx);
      } catch (error, stack) {
        check(false, '$name: 运行抛错', '$error\n$stack');
      }
    }

    if (failures.isNotEmpty) {
      fail(
        '${files.length} 条 fixture；${failures.length}/$checks 项不通过\n'
        '${failures.map((line) => '  - $line').join('\n')}',
      );
    }
    // 断言数不必与电脑侧（486）相等：fixtures 是"场景 → 结论"，两侧各自表述。
    // 但**每一条 fixture 的每个 expect 键都必须被走到** —— 数量太少就说明漏了整块。
    expect(checks, greaterThan(300), reason: '断言数太少（$checks），说明有整块期望没被走到');
  });
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i += 1) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
