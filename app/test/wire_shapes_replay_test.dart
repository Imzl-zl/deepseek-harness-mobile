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

import 'package:dsh_mobile/core/endpoint.dart' show parseEndpointList;
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/command.dart';
import 'package:dsh_mobile/model/model_catalog.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/wire/rpc/permission.dart';
import 'package:dsh_mobile/wire/rpc/projections.dart';
import 'package:dsh_mobile/wire/rpc/repo.dart';
import 'package:dsh_mobile/wire/rpc/session.dart';
import 'package:dsh_mobile/wire/rpc/settings.dart';
import 'package:dsh_mobile/wire/rpc/workspace.dart';
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

/// 取某个方法的**第一条**样本（金样按"方法 → 样本数组"存，这里只要我们收的单形态）。
Map<String, Object?> _sampleOf(Map<String, Object?> golden, String method) {
  final samples = golden[method];
  expect(samples, isA<List<Object?>>(), reason: '金样缺 $method 的样本数组');
  final first = (samples! as List<Object?>).first;
  expect(first, isA<Map<String, Object?>>(), reason: '$method 的样本不是对象');
  return (first as Map).cast<String, Object?>();
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

  // ---- 会话面其余方法（第 2 批 A1）：create / select-model / modelCatalog ----

  test('session.create：读出的 sid 等于金样里写的那个', () {
    final sample = _sampleOf(golden, 'session.create');
    final reading = readCreatedSid(sample);
    expect(reading, isA<WireOk<String>>());
    expect((reading as WireOk<String>).value, sample['sid']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('session.create 缺 sid ⇒ WireBad + 计数 1（新建会话拿不到 sid 必须响）', () {
    final reading = readCreatedSid({'agentPreset': 'standard'});
    expect(reading, isA<WireBad<String>>());
    expect(valueOrReport(reading, 'session.create'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('session.select-model：selected 里的 provider/model 等于金样', () {
    final sample = _sampleOf(golden, 'session.select-model');
    final selected = (sample['selected']! as Map).cast<String, Object?>();
    final reading = readSelectedModel(sample);
    expect(reading, isA<WireOk<ModelRef>>());
    final ref = (reading as WireOk<ModelRef>).value;
    expect(ref.provider, selected['provider']);
    expect(ref.model, selected['model']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('session.select-model 的 selected 缺 model ⇒ WireBad（不许拿请求值冒充回执）', () {
    final reading = readSelectedModel({
      'selected': {'provider': 'deepseek'},
    });
    expect(reading, isA<WireBad<ModelRef>>());
    expect(valueOrReport(reading, 'session.select-model'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('session.modelCatalog：available 为真时目录解得出，分组数与金样一致', () {
    final sample = _sampleOf(golden, 'session.modelCatalog');
    expect(sample['available'], isTrue);
    final catalog = (sample['catalog']! as Map).cast<String, Object?>();
    final groups = catalog['groups']! as List<Object?>;
    final reading = readModelCatalog(sample);
    expect(reading, isA<WireOk<ModelCatalog?>>());
    final value = (reading as WireOk<ModelCatalog?>).value;
    expect(value?.groups.length, groups.length);
    expect(WireDiagnostics.badCount, 0);
  });

  test('session.modelCatalog：available=false 是电脑侧明说 ⇒ WireOk(null)，不计错', () {
    final reading = readModelCatalog({'available': false});
    expect(reading, isA<WireOk<ModelCatalog?>>());
    expect((reading as WireOk<ModelCatalog?>).value, isNull);
    expect(WireDiagnostics.badCount, 0, reason: '"目录拿不到"不是形状错');
  });

  test('session.modelCatalog：说 available 却不给 catalog ⇒ WireBad + 计数 1', () {
    final reading = readModelCatalog({'available': true});
    expect(reading, isA<WireBad<ModelCatalog?>>());
    expect(valueOrReport(reading, 'session.modelCatalog'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('应答无人消费的四个方法：金样里钉住线上形状（回执是 {accepted:true}）', () {
    // cancel / updateQueue / prompt / subagent.prompt：手机侧**不读应答**，
    // 所以 App 没有 decoder（造一个没人读的 decoder 是假象）。
    // 但金样照样收它们：连接器哪天把回执改成 `{ok:true}`，这里会红，
    // 而那一刻正是"我们该决定要不要读它"的时候。
    for (final method in const [
      'session.cancel',
      'session.updateQueue',
      'session.prompt',
      'subagent.prompt',
    ]) {
      final sample = _sampleOf(golden, method);
      expect(sample['accepted'], isTrue, reason: '$method 的回执形状变了');
    }
  });

  // ---- 投影面（A2）：一个方法打开全部只读面，应答是**扁平 values** ----

  test('session.projections：14 个被消费的键都解得出（期望值来自金样）', () {
    final sample = _sampleOf(golden, 'session.projections');
    final reading = readSessionProjections(sample);
    expect(reading, isA<WireOk<SessionProjections>>());
    final projections = (reading as WireOk<SessionProjections>).value;

    Map<String, Object?> mapOf(Object? raw) =>
        (raw! as Map).cast<String, Object?>();

    // 标题 / 模型
    expect(projections.title, sample['title']);
    final selection = mapOf(sample['modelSelection']);
    final next = mapOf(selection['next'] ?? selection['lastUsed']);
    expect(projections.modelSelection?.provider, next['provider']);
    expect(projections.modelSelection?.model, next['model']);

    // 统计条三项
    final usage = mapOf(sample['tokenUsage']);
    expect(
      projections.tokenUsage?.uncachedInputTokens,
      usage['uncachedInputTokens'],
    );
    final stats = mapOf(sample['sessionStats']);
    expect(projections.sessionStats?.turns, stats['turns']);
    expect(projections.sessionStats?.decodeTokens, stats['decodeTokens']);
    final pressure = mapOf(sample['contextPressure']);
    expect(
      projections.contextPressure?.contextWindow,
      pressure['contextWindow'],
    );
    final breakdown = mapOf(sample['contextBreakdown']);
    expect(
      projections.contextBreakdown?.systemTokens,
      breakdown['systemTokens'],
    );

    // 轮次大纲：条数与每轮 turn 都照金样
    final outline = (sample['turnOutline']! as List).cast<Object?>();
    expect(projections.turnOutline.length, outline.length);
    expect(projections.turnOutline.first.turn, mapOf(outline.first)['turn']);

    // 权限 / 预设
    expect(
      projections.permissionValue,
      mapOf(sample['permissions'])['currentValue'],
    );
    expect(projections.agentPreset, sample['agentPreset']);

    // 子智能体目录（连接器会把 id 过别名表，所以只比条数与 label）
    final catalog = (sample['subagentCatalog']! as List).cast<Object?>();
    expect(projections.subagentCatalog.length, catalog.length);
    expect(
      projections.subagentCatalog.first.label,
      mapOf(catalog.first)['label'],
    );

    // 计时 / 轨迹 / 附件上限 / 收件箱
    final timing = mapOf(sample['subagentTiming']);
    expect(projections.subagentTiming?.settledMs, timing['settledMs']);
    final turns = (mapOf(sample['trajectory'])['turns']! as List)
        .cast<Object?>();
    expect(projections.trajectory?.turns.length, turns.length);
    final limits = mapOf(sample['imageLimits']);
    expect(projections.imageLimits?.maxImageBytes, limits['maxImageBytes']);
    expect(projections.inbox, isNotNull);

    expect(WireDiagnostics.badCount, 0, reason: '真实形状的 14 个键一个都不该算漂移');
  });

  test('session.projections 应答不是对象 ⇒ WireBad + 计数 1', () {
    final reading = readSessionProjections([
      {'title': 'x'},
    ]);
    expect(reading, isA<WireBad<SessionProjections>>());
    expect(valueOrReport(reading, 'session.projections'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('session.projections 的 values 有非字符串键 ⇒ 计 1，其余字段照常', () {
    // 线上 JSON 不可能出现非字符串键（JSON 的键恒是字符串），所以这是"畸形数据"，
    // 不是漂移面；但它必须**留声**而不是静默丢掉。
    final reading = readSessionProjections(<Object?, Object?>{
      'title': '标题还在',
      42: '垃圾',
    });
    expect(reading, isA<WireOk<SessionProjections>>());
    expect((reading as WireOk<SessionProjections>).value.title, '标题还在');
    expect(WireDiagnostics.badCount, 1);
  });

  // ---- 工作区面（B1）：分组 + 两列 id 同一份应答，七种应答都是"整份真值" ----

  test('workspace.list：分组与两列 id 都等于金样（含 createdAt）', () {
    final sample = _sampleOf(golden, 'workspace.list');
    final reading = readWorkspaceList(sample);
    expect(reading, isA<WireOk<WorkspaceSnapshot>>());
    final snapshot = (reading as WireOk<WorkspaceSnapshot>).value;

    final rows = (sample['workspaces']! as List).cast<Object?>();
    expect(snapshot.groups.length, rows.length);
    final first = (rows.first! as Map).cast<String, Object?>();
    final group = snapshot.groups.first;
    expect(group.workspaceId, first['workspaceId']);
    expect(group.title, first['title']);
    expect(group.path, first['path']);
    expect(
      group.createdAt,
      first['createdAt'],
      reason: 'createdAt 必须过线（2026-10-25 才修的那一处）',
    );
    expect(group.sessionIds, (first['sessionIds']! as List).cast<String>());

    expect(
      snapshot.archivedSessionIds,
      (sample['archivedSessionIds']! as List).toSet(),
    );
    expect(
      snapshot.pinnedSessionIds,
      (sample['pinnedSessionIds']! as List).toSet(),
    );
    expect(WireDiagnostics.badCount, 0);
  });

  test('workspace.list 缺 pinnedSessionIds ⇒ WireBad + 计数 1（三列都是恒发的）', () {
    final reading = readWorkspaceList({
      'workspaces': <Object?>[],
      'archivedSessionIds': <String>[],
    });
    expect(reading, isA<WireBad<WorkspaceSnapshot>>());
    expect(valueOrReport(reading, 'workspace.list'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('"整份真值"非空却全非法 ⇒ WireBad（落空集会静默清空归档/置顶）', () {
    final reading = readSessionOrder({
      'sessionIds': ['', ''],
    });
    expect(reading, isA<WireBad<List<String>>>());
    expect(valueOrReport(reading, 'workspace.insertSessionBefore'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('workspace 的四种"整份集合/顺序"应答都与金样一致', () {
    for (final method in const ['workspace.pin', 'workspace.unpin']) {
      final sample = _sampleOf(golden, method);
      final reading = readPinnedSet(sample);
      expect(reading, isA<WireOk<Set<String>>>());
      expect(
        (reading as WireOk<Set<String>>).value,
        (sample['pinnedSessionIds']! as List).toSet(),
        reason: method,
      );
    }
    for (final method in const ['workspace.archive', 'workspace.unarchive']) {
      final sample = _sampleOf(golden, method);
      final reading = readArchivedSet(sample);
      expect(reading, isA<WireOk<Set<String>>>());
      expect(
        (reading as WireOk<Set<String>>).value,
        (sample['archivedSessionIds']! as List).toSet(),
        reason: method,
      );
    }
    final order = _sampleOf(golden, 'workspace.insertSessionBefore');
    final orderReading = readSessionOrder(order);
    expect(orderReading, isA<WireOk<List<String>>>());
    expect(
      (orderReading as WireOk<List<String>>).value,
      (order['sessionIds']! as List).cast<String>(),
    );

    final workspaceOrder = _sampleOf(golden, 'workspace.insertBefore');
    final idsReading = readWorkspaceOrder(workspaceOrder);
    expect(idsReading, isA<WireOk<List<String>>>());
    expect(
      (idsReading as WireOk<List<String>>).value,
      (workspaceOrder['workspaceIds']! as List).cast<String>(),
    );
    expect(WireDiagnostics.badCount, 0);
  });

  // ---- B2：权限 / 设置 / 预设三个目录面 ----

  test('permission.catalog：available 为真时预设表解得出，条目数与金样一致', () {
    final sample = _sampleOf(golden, 'permission.catalog');
    expect(sample['available'], isTrue);
    final catalog = (sample['catalog']! as Map).cast<String, Object?>();
    final reading = readPermissionCatalog(sample);
    expect(reading, isA<WireOk<PermissionCatalog?>>());
    final value = (reading as WireOk<PermissionCatalog?>).value;
    expect(value?.options.length, (catalog['options']! as List).length);
    expect(value?.defaultPreset, catalog['defaultPreset']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('permission.catalog：available=false 是明说 ⇒ WireOk(null)，不计错', () {
    final reading = readPermissionCatalog({'available': false});
    expect(reading, isA<WireOk<PermissionCatalog?>>());
    expect((reading as WireOk<PermissionCatalog?>).value, isNull);
    expect(WireDiagnostics.badCount, 0);
  });

  test('permission.catalog：说 available 却不给 catalog ⇒ WireBad + 计数 1', () {
    final reading = readPermissionCatalog({'available': true});
    expect(reading, isA<WireBad<PermissionCatalog?>>());
    expect(
      valueOrReport<PermissionCatalog?>(reading, 'permission.catalog'),
      isNull,
    );
    expect(WireDiagnostics.badCount, 1);
  });

  test('permission.switch 与 command.execute 的回执形状相同（matched + execution）', () {
    final sample = _sampleOf(golden, 'permission.switch');
    final reading = readPermissionSwitch(sample);
    expect(reading, isA<WireOk<CommandOutcome>>());
    final outcome = (reading as WireOk<CommandOutcome>).value;
    expect(outcome.matched, sample['matched']);
    final execution = (sample['execution']! as Map).cast<String, Object?>();
    final result = (execution['result']! as Map).cast<String, Object?>();
    expect(outcome.text, result['text']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('settings.describe：一个 section 的 ns/revision/values 等于金样', () {
    final sample = _sampleOf(golden, 'settings.describe');
    final sections = (sample['sections']! as List).cast<Object?>();
    final first = (sections.first! as Map).cast<String, Object?>();
    final reading = readSettings(sample);
    expect(reading, isA<WireOk<List<SettingSectionWire>>>());
    final list = (reading as WireOk<List<SettingSectionWire>>).value;
    expect(list.length, sections.length);
    expect(list.first.ns, first['ns']);
    expect(list.first.revision, first['revision']);
    expect(list.first.values, first['values']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('settings.update：section 里的新值解得出；section 为 null 是合法应答', () {
    final sample = _sampleOf(golden, 'settings.update');
    final section = (sample['section']! as Map).cast<String, Object?>();
    final reading = readSettingSection(sample);
    expect(reading, isA<WireOk<SettingSectionWire?>>());
    final value = (reading as WireOk<SettingSectionWire?>).value;
    expect(value?.ns, section['ns']);
    expect(value?.values, section['values']);

    final nullReading = readSettingSection({'section': null});
    expect(nullReading, isA<WireOk<SettingSectionWire?>>());
    expect((nullReading as WireOk<SettingSectionWire?>).value, isNull);
    expect(WireDiagnostics.badCount, 0, reason: 'section:null 不是漂移');

    final bad = readSettingSection({'sections': <Object?>[]});
    expect(bad, isA<WireBad<SettingSectionWire?>>());
    expect(valueOrReport<SettingSectionWire?>(bad, 'settings.update'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  // ---- B3：能力面（repo.info）与端点自报（endpoint.describe）----

  test('repo.info：三个能力位等于金样里的 caps，methods 只数条数', () {
    final sample = _sampleOf(golden, 'repo.info');
    final caps = (sample['caps']! as Map).cast<String, Object?>();
    final reading = readRepoInfo(sample);
    expect(reading, isA<WireOk<RepoInfoWire>>());
    final info = (reading as WireOk<RepoInfoWire>).value;
    expect(info.mentionsAvailable, caps['references'] == true);
    expect(info.filesAvailable, caps['files'] == true);
    expect(info.pluginsAvailable, caps['plugins'] == true);
    // 金样采样时把 `methods` 归一掉了（它会随任何方法增减而变），所以这里是 0 条。
    expect(info.methodCount, 0);
    expect(info.dshVersion, sample['dshVersion']);
    expect(WireDiagnostics.badCount, 0);
  });

  test('repo.info 缺 caps ⇒ WireBad + 计数 1（它由连接器无条件写出）', () {
    final reading = readRepoInfo({'protocol': 1, 'aliasVersion': 7});
    expect(reading, isA<WireBad<RepoInfoWire>>());
    expect(valueOrReport(reading, 'repo.info'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('endpoint.describe：端点表逐条等于金样（顺序即偏好，原样保留）', () {
    final sample = _sampleOf(golden, 'endpoint.describe');
    final rows = (sample['endpoints']! as List).cast<Object?>();
    final endpoints = parseEndpointList(sample);
    expect(endpoints.length, rows.length);
    for (var index = 0; index < rows.length; index += 1) {
      final row = (rows[index]! as Map).cast<String, Object?>();
      expect(endpoints[index].url, row['url'], reason: '第 ${index + 1} 条的地址');
      expect(endpoints[index].kind.name, row['kind']);
    }
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
