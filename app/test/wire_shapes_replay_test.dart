/// 连接器**金样**的跨工程回放闸门：`connector/tests/fixtures/wire-shapes.json`。
///
/// ## 这一组守什么
///
/// 1. **文件必须存在**。缺失时**直接 `fail`，不许 `skip`** —— 跳过会让门禁静默退化成空跑，
///    而空跑这一档在三次事故里一次都没被拦住过。
/// 2. **两个已收的方法键缺一不可**（`session.list` / `session.projections`）。少一个就红。
/// 3. **`session.list` 的每一行都解得出**（`WireBad` 数 0），且解出的每个字段都等于
///    金样里写的那个值 —— 期望值**全部取自金样本身**，不复述一份手抄常量
///    （手抄的那份会在实现变化时假装通过，教训第九条的近亲）。
/// 4. **形状错要响**：缺 `sid` ⇒ 整行丢 + 计数 1；`projections.values` 不是映射
///    ⇒ 该行的四个投影字段降级 + 计数 1（**不丢整行**）。
/// 5. **金样不许退化成四行一样的行**：四个可选键（`parentSessionId` / `cwd` / `model` /
///    `projections`）各要有"有"与"没有"两侧，否则"把可选键当必填"的 decoder 也全绿。
///
/// ## 样本从哪来（为什么不是"真机抓一份"）
///
/// 由**连接器的测试**调真实 handler 产出、深比较守住（`connector/tests/wire-shapes.test.ts`）。
/// 真样本是一次性快照，连接器改了应答它不会变，用例永远绿 —— 这正是
/// `memory.md` 教训第九条的形态，只是把"手捏的形状"换成了"过期的真形状"。
///
/// ## 失败的判读方向
///
/// 这个文件红了，通常意味着**连接器的应答变了**（连接器那边那条用例会一起红）。
/// 正确的处置是：确认改动是有意的 ⇒ 连接器侧 `UPDATE_WIRE_SHAPES=1` 重生成
/// ⇒ 同步本仓的解码（`app/lib/wire/rpc/`）。**不要**只改这里让它变绿。
///
/// Note: 取舍与代价（跨工程测试耦合、文件缺失必须 fail）见
/// `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/wire/rpc/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 金样相对 `app/`（`flutter test` 的工作目录）的路径。
const String kGoldenWireShapes = '../connector/tests/fixtures/wire-shapes.json';

/// 本轮已收进金样的方法。**只许增不许减**：少一个键就说明生成侧缩水了。
const List<String> kSampledMethods = ['session.list', 'session.projections'];

/// `session.list` 的恒发键（`connector/src/handlers.ts:740-744` 无条件写出）。
const List<String> kUnconditionalRowKeys = [
  'sid',
  'updatedAt',
  'running',
  'blank',
  'subagent',
];

/// 四个**可选**键（生产侧按条件展开，`connector/src/handlers.ts:750-768`）。
const List<String> kOptionalRowKeys = [
  'parentSessionId',
  'cwd',
  'model',
  'projections',
];

String get _missingFileHint =>
    '金样不存在：$kGoldenWireShapes\n'
    '这一条**不许 skip**：跳过等于让整套形状门禁静默退化成空跑。'
    '重新生成：cd connector; UPDATE_WIRE_SHAPES=1 pnpm exec tsx --test tests/wire-shapes.test.ts';

Map<String, Object?> _golden() {
  final file = File(kGoldenWireShapes);
  if (!file.existsSync()) fail(_missingFileHint);
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('金样顶层不是对象：$kGoldenWireShapes');
  }
  return decoded;
}

/// 生成用例时用的"读不到就空"版本（读不到时下面会注册一条明确失败的用例，
/// 而不是让整个文件加载失败 —— 两者都红，但后者的报错看不出是人话）。
List<Map<String, Object?>> _rowsOf(Map<String, Object?> golden) {
  final samples = golden['session.list'];
  if (samples is! List || samples.isEmpty) return const [];
  final first = samples.first;
  if (first is! Map) return const [];
  final rows = first['sessions'];
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map) row.cast<String, Object?>(),
  ];
}

/// 一行的 `projections` **信封**里的 `values`（**不是扁平 map**，见 decoder 头注）。
Map<String, Object?>? _valuesOf(Map<String, Object?> row) {
  final projections = row['projections'];
  if (projections is! Map) return null;
  final values = projections['values'];
  return values is Map ? values.cast<String, Object?>() : null;
}

/// 这一行覆盖了哪几种形态（名字从数据里长出来，所以不会与金样脱节）。
String _rowKindOf(Map<String, Object?> row) {
  final parts = <String>[
    if (row.containsKey('parentSessionId')) '带 parentSessionId',
    if (row.containsKey('model')) '带顶层 model',
    if (row.containsKey('projections')) '带 projections 信封',
  ];
  if (parts.isEmpty) {
    // 四个可选键一个都没有 = 冷行（从没打开过、也没有活 agent 的会话）。
    return row['blank'] == true ? '冷行（只有恒发键，blank）' : '只有恒发键';
  }
  return parts.join(' + ');
}

void main() {
  late Map<String, Object?> golden;
  final reported = <String>[];

  setUp(() {
    golden = _golden();
    reported.clear();
    WireDiagnostics.reset();
    WireDiagnostics.sink = (event, detail) => reported.add('$event: $detail');
  });

  tearDown(() {
    WireDiagnostics.sink = null;
    WireDiagnostics.reset();
  });

  test('金样在：两个已收的方法键缺一不可（不许缩水）', () {
    for (final method in kSampledMethods) {
      expect(
        golden.containsKey(method),
        isTrue,
        reason: '金样少了 $method —— 生成侧的 SAMPLES 被删了，或本文件被手改过',
      );
    }
  });

  test('每条样本都是对象，且每个方法至少一条样本', () {
    for (final method in kSampledMethods) {
      final samples = golden[method];
      expect(
        samples,
        isA<List<Object?>>(),
        reason: '$method 的样本必须是数组（多形态方法放多条）',
      );
      final list = samples! as List<Object?>;
      expect(list, isNotEmpty, reason: '$method 一条样本都没有：断言会在空集上全绿');
      for (var index = 0; index < list.length; index += 1) {
        expect(
          list[index],
          isA<Map<String, Object?>>(),
          reason: '$method 的第 ${index + 1} 条样本不是对象',
        );
      }
    }
  });

  // ---- 第 1 批：`session.list` 行的解码（4 种行各一条用例，诊断更快）----

  var rowSamples = const <Map<String, Object?>>[];
  var loadFailure = '';
  try {
    rowSamples = _rowsOf(_golden());
  } on Object catch (error) {
    loadFailure = '$error';
  }

  if (loadFailure.isNotEmpty) {
    // 文件缺失/不是 JSON：注册一条明确失败的用例，别让整个文件加载失败
    // （两者都红，但后者的报错看不出是人话）。
    test(
      '金样读不到 ⇒ 这里必须红（不许静默跳过）',
      () => fail('$loadFailure\n$_missingFileHint'),
    );
    return;
  }

  if (rowSamples.isEmpty) {
    test('金样里的 session.list 一行都没有', () => fail('金样缩水：$kGoldenWireShapes'));
    return;
  }

  test('金样的行覆盖"可选键有与没有"两侧，且每行都有恒发键', () {
    for (final key in kOptionalRowKeys) {
      expect(
        rowSamples.any((row) => row.containsKey(key)),
        isTrue,
        reason: '金样里没有一行带 $key —— 这个可选键的"有"那一半等于没测',
      );
      expect(
        rowSamples.any((row) => !row.containsKey(key)),
        isTrue,
        reason: '金样里每一行都带 $key —— "缺席"那一半等于没测（decoder 把它当必填也全绿）',
      );
    }
    for (final row in rowSamples) {
      for (final key in kUnconditionalRowKeys) {
        expect(
          row.containsKey(key),
          isTrue,
          reason: '金样里有一行缺恒发键 $key —— 生成侧的假行写漏了',
        );
      }
    }
  });

  for (var index = 0; index < rowSamples.length; index += 1) {
    final row = rowSamples[index];
    test('第 ${index + 1} 行（${_rowKindOf(row)}）解得出，且每个字段都等于金样', () {
      final reading = readSessionRow(row);
      expect(
        reading,
        isA<WireOk<SessionSummary>>(),
        reason:
            '金样里的行必须解得出：'
            '${reading is WireBad<SessionSummary> ? reading.detail : reading}',
      );
      _expectRowMatchesGolden(row, (reading as WireOk<SessionSummary>).value);
      expect(reported, isEmpty, reason: '正常行不该出声');
      expect(WireDiagnostics.badCount, 0);
    });
  }

  test('缺 sid ⇒ 整行丢，且计数恰好 1（恒发键缺失是漂移，不是"少一个字段"）', () {
    final broken = Map<String, Object?>.from(rowSamples.first)..remove('sid');
    final reading = readSessionList({
      'sessions': [broken],
    });

    expect(reading, isA<WireOk<List<SessionSummary>>>(), reason: '信封没坏，坏的是行');
    expect((reading as WireOk<List<SessionSummary>>).value, isEmpty);
    expect(WireDiagnostics.badCount, 1);
    expect(reported, hasLength(1));
  });

  test('projections 的 values 不是映射 ⇒ 该行仍解得出、四个投影字段降级、计数恰好 1', () {
    // 挑一行"带信封且没有顶层 model"的：这样四个投影字段的来源只有信封，
    // 断言"全降级"才不会被顶层 `model` 的兜底混进来。
    final target = rowSamples
        .where((row) => row['projections'] != null && row['model'] == null)
        .toList();
    expect(target, isNotEmpty, reason: '金样里没有"带信封且无顶层 model"的行 —— 这条用例失去意义了');

    final broken = Map<String, Object?>.from(
      target.first,
    )..['projections'] = {'kind': 'sequenced', 'asOfSeq': 1, 'values': '这不是映射'};
    final reading = readSessionRow(broken);

    expect(
      reading,
      isA<WireOk<SessionSummary>>(),
      reason: '信封坏了不丢整行（丢一行比空标题坏得多）',
    );
    final summary = (reading as WireOk<SessionSummary>).value;
    expect(summary.title, '', reason: '读不到标题就按未命名处理');
    expect(summary.model, isNull);
    expect(summary.subagentTiming, isNull);
    expect(summary.tokenUsage, isNull);
    expect(WireDiagnostics.badCount, 1, reason: '信封坏**报一次**，不是四个字段各报一次');
    // 恒发键照旧可读 —— 这一行仍然是一条可用的会话。
    expect(summary.sid, broken['sid']);
    expect(summary.running, broken['running']);
  });
}

/// 逐字段比对：**期望值全部来自金样里那一行**，不写常量。
void _expectRowMatchesGolden(Map<String, Object?> row, SessionSummary summary) {
  // 恒发键。
  expect(summary.sid, row['sid']);
  expect(summary.updatedAt, row['updatedAt']);
  expect(summary.running, row['running']);
  expect(summary.blank, row['blank']);
  expect(summary.subagent, row['subagent']);

  // 可选键：金样里缺席 ⇒ 必须是 null。
  expect(summary.parentSid, row['parentSessionId']);
  expect(summary.cwd, row['cwd']);

  // 标题只在信封的 `values.title` 里；**空/缺席是正常**（未命名会话）。
  final values = _valuesOf(row);
  final title = values?['title'];
  final expectedTitle = title is String ? title : '';
  expect(summary.title, expectedTitle);
  expect(
    summary.displayTitle,
    expectedTitle.isEmpty
        ? SessionSummary.kUntitledSessionTitle
        : expectedTitle,
  );

  // 模型：投影提示优先（`next ?? lastUsed`），否则行顶层的 `model`。
  final selection = values?['modelSelection'];
  final Object? expectedModel = selection is Map
      ? (selection['next'] ?? selection['lastUsed'])
      : row['model'];
  if (expectedModel is Map) {
    expect(summary.model?.provider, expectedModel['provider']);
    expect(summary.model?.model, expectedModel['model']);
    expect(summary.model?.reasoningEffort, expectedModel['reasoningEffort']);
  } else {
    expect(summary.model, isNull, reason: '金样里没有可用的模型 ⇒ 解出来必须是 null（不许猜）');
  }

  // 两个投影值：逐字段照金样。
  final timing = values?['subagentTiming'];
  if (timing is Map) {
    expect(summary.subagentTiming?.settledMs, timing['settledMs']);
    final active = timing['active'];
    expect(
      summary.subagentTiming?.activeSince,
      active is Map ? active['since'] : null,
    );
    expect(
      summary.subagentTiming?.activeThrough,
      active is Map ? active['through'] : null,
    );
  } else {
    expect(summary.subagentTiming, isNull);
  }

  final usage = values?['tokenUsage'];
  if (usage is Map) {
    expect(
      summary.tokenUsage?.uncachedInputTokens,
      usage['uncachedInputTokens'],
    );
    expect(summary.tokenUsage?.outputTokens, usage['outputTokens']);
    expect(summary.tokenUsage?.cacheReadTokens, usage['cacheReadTokens']);
    expect(summary.tokenUsage?.cacheWriteTokens, usage['cacheWriteTokens']);
  } else {
    expect(summary.tokenUsage, isNull);
  }
}
