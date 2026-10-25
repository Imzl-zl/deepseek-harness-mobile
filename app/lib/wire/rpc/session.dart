/// `session.list` 的**唯一入口**：发请求 + 解码。方法名与参数形状只在这个文件里。
///
/// ## 它为什么在 `wire/` 而不是 `data/`
///
/// 协议知识有三样：**方法名、参数形状、应答字段**。只要还有第二处出现，就会有一处先漂，
/// 而漂的表现是**静默空值**（三次事故都是这个形态）。把三样收进一个文件之后，
/// "还有几处漏在 `wire/` 外面"变成了一个可以数的数字 ——
/// `app/tools/verify-rpc-single-caller.mjs` 的预算（从 39 递减，终态 0）。
/// 搬走方法却把 `client.call<…>('session.list')` 留在调用方，预算就降不下来 ——
/// 那正是这个门禁在机械执行的事。
///
/// ## 形状的出处（不是猜的）
///
/// - **应答 `{sessions: [...]}`**：`connector/src/handlers.ts:738-770`。
///   **行是连接器自造的，不是宿主形状** —— 逐字段构造、不 spread，`dshSessionId` 绝不过线
///   （`connector/src/handlers.ts:719-720` 的原话）。所以形状出处是**连接器**，
///   不是 `packages/...`（宿主那一层只有 `SessionSummaryRow`，见 `connector/src/dsh/sessions.ts:132-162`）。
/// - **必填 / 可选的分界看生产方式，不看名字**：`handlers.ts:740-744` **无条件写出**的五个键
///   （`sid` / `updatedAt` / `running` / `blank` / `subagent`）缺失 = 漂了 ⇒ [WireBad]；
///   被 `...(cond ? {} : …)` 包住的四个键（`parentSessionId` `:750`、`model` `:754-759`、
///   `cwd` `:760`、`projections` `:766-768`）缺失 = 正常 ⇒ `null`。
/// - **`model` 不是恒有的键**：`handlers.ts:754-759` 只在 `deps.models` 存在**且**
///   `modelOf(sid)` 有值时才写。子会话不在活 agent 那张表里 ⇒ 整键缺席（这就是它必须可空的原因）。
/// - **行的 `.projections` 是信封** `{kind, asOfSeq, values}`
///   （`connector/src/dsh/sessions.ts:333-341` 逐键重建、`handlers.ts:766-768` 过线）。
///   **这不是扁平 map** —— 同名方法 `session.projections` 的应答才是扁平 `values`
///   （`connector/src/dsh/projections.ts:68-72` 拆信封、`:94` 返回），那是第 3 批的事。
///   同一个名字两种形状、读错的表现是静默空值：金样里两条并存就是为了让读错的人**红**。
/// - **`pendingCount` / `itemCount` 是本地派生**（`app/lib/data/app_model.dart` 的
///   `_applySessionList`），不由这个文件填 —— 那是"跨请求的汇总"，不是线上的字段。
///
/// ## 产出的是已有模型类
///
/// `SessionSummary`（`app/lib/model/chat_item.dart:778-913`），**不新造 DTO**：
/// `chat_item.dart` 不 import `wire/`，所以 `wire → model` 是单向的，不成环。
///
/// ## 失败语义
///
/// 三态内核见 `wire/reading.dart`。本文件的两档分界是有意的：
/// - **信封错**（`{sessions: [...]}` 都没了）⇒ [WireBad]：整个列表读不出来，必须响。
/// - **行级问题**（缺恒发键 / 可选键读不出）⇒ **丢那一行或降级那个字段 + 计数一次**，
///   **不升级成 Bad**：一条坏行让整个列表消失，比少一行或空标题坏得多。
///
/// ## 本轮**不**搬的方法（免得下一个人以为漏了）
///
/// `session.cancel` / `session.updateQueue` / `job.follow` / `job.unfollow` /
/// `interaction.respond` / `session.prompt` / `subagent.prompt` —— 这七个的应答今天
/// **没有任何一侧断言**（连返回形态都不判），属于"没有形状可断言"，不是"忘了搬"。
/// **将来有人开始读它们的应答，那一刻才搬**（`session.prompt` 最终必须搬，否则预算归不了零，
/// 那是第 7 批的 `sendPrompt(...)`）。
///
/// Note: 取舍与批次顺序见 `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`
/// 与 `.agents/notes/proposed/2026-10-25-wire-design-review.md`。
library;

import '../../core/sync_client.dart';
import '../../model/chat_item.dart';
import '../../model/session_stats.dart' show parseTokenUsage;
import '../../model/subagent.dart' show parseSubagentTiming;
import '../reading.dart';

/// 消费方一次拿齐"三态内核 + `session.list` 解码"（与 `wire/events.dart` 同一条：
/// RPC 面也 re-export 内核，**全 app 只有一套失败语义**）。
export '../reading.dart';

/// 方法名只在这里出现一次（`connector/src/handlers.ts:716`）。
const String _kSessionList = 'session.list';

/// 发请求 + 解码，**`session.list` 的唯一调用口**。
///
/// 收 [SyncClient]（`app/lib/core/sync_client.dart:136-144` 的既有端口）而**不新造
/// `RpcCaller` 之类的平行抽象**：端口本来就有，再造一个只是重复。
/// 依赖方向也是对的：适配器（`wire/rpc`）依赖端口（`SyncClient`）。
///
/// 参数恒是空对象（`connector/src/handlers.ts:716` 的 handler 不读参数）。
Future<List<SessionSummary>> loadSessionList(SyncClient client) async {
  final result = await client.call<Object?>(_kSessionList, const {});
  // 形状错的计数与出声走 `valueOrReport`（唯一出口）；`null` 只剩"读不出来"一个含义。
  return valueOrReport(readSessionList(result), _kSessionList) ?? const [];
}

/// 纯解码：给回放用例与"已经拿到应答"的调用方（**不收 client**，用例里不启传输）。
///
/// 应答 `{sessions: [...]}`（`connector/src/handlers.ts:738`）。
/// **裸数组不算**：连接器从来只回这个对象形状；早先那份"两种都认"的写法让
/// "认不出就必须留声"永远不成立 —— 现在裸数组 ⇒ [WireBad]（空列表 + 计数 1）。
WireReading<List<SessionSummary>> readSessionList(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是 `{sessions: [...]}`（连接器从未回过别的形状）');
  }
  final rows = result['sessions'];
  if (rows is! List) return const WireBad('应答里没有 sessions 数组');
  final out = <SessionSummary>[];
  for (final row in rows) {
    // 行级问题在这里统一计数（事件名恒是方法名，细节里带字段名）：
    // 一条坏行只丢那一行，**不让整个列表消失**。
    final summary = valueOrReport(readSessionRow(row), _kSessionList);
    if (summary != null) out.add(summary);
  }
  return WireOk(List<SessionSummary>.unmodifiable(out));
}

/// 一行。缺 `sid` / 恒发键 ⇒ [WireBad]（整行丢 + 计数）；
/// 四个可选键读不出 ⇒ 该字段降级为 `null` + 计数（**不丢整行**）。
///
/// 行级 decoder **不产 [WireSkip]**：每一行都该是一条会话，没有"不是我要的行"这种情形。
WireReading<SessionSummary> readSessionRow(Object? row) {
  if (row is! Map) return const WireBad('行不是对象');

  // ---- 恒发键：`handlers.ts:740-744` 无条件写出，缺了就是漂了 ----
  final sid = row['sid'];
  if (sid is! String || sid.isEmpty) {
    return const WireBad('缺 sid（别名，`handlers.ts:740`）');
  }
  final updatedAt = row['updatedAt'];
  if (updatedAt is! num) {
    return const WireBad('updatedAt 不是数字（`handlers.ts:741`）');
  }
  final running = row['running'];
  if (running is! bool) {
    return const WireBad('running 不是布尔（`handlers.ts:742`）');
  }
  final blank = row['blank'];
  if (blank is! bool) {
    return const WireBad('blank 不是布尔（`handlers.ts:743`）');
  }
  final subagent = row['subagent'];
  if (subagent is! bool) {
    return const WireBad('subagent 不是布尔（`handlers.ts:744`）');
  }

  // ---- 可选键：缺失是正常（生产侧按条件展开），**在但读不出**才计一次数 ----
  final parentSid = _parentSidOf(row);
  final cwd = _cwdOf(row);

  // `model`：行顶层那份来自**活 agent**（`connector/src/dsh/models.ts` 的 `modelOf`），
  // 子会话取不到 ⇒ 整键缺席。所以它**不是**恒发键（`handlers.ts:754-759`）。
  final model = _optionalModelOf(row['model']);

  final values = _envelopeValuesOf(row['projections']);
  final modelSelection = _modelSelectionOf(values);

  return WireOk(
    SessionSummary(
      sid: sid,
      title: _titleOf(values),
      updatedAt: updatedAt.toInt(),
      running: running,
      blank: blank,
      subagent: subagent,
      parentSid: parentSid,
      // 投影提示优先，行顶层兜底：子会话的 `model` 恒缺席，只认顶层会让
      // 子智能体页面的输入栏显示「未选择」（`chat_item.dart:852-862` 记着这条）。
      model: modelSelection ?? model,
      cwd: cwd,
      // 两个投影值解析器仍住 `model/`：它们是**投影值**的解析（第 3 批才搬），
      // 这里只负责"从信封的哪一层取"。
      subagentTiming: parseSubagentTiming(values?['subagentTiming']),
      tokenUsage: parseTokenUsage(values?['tokenUsage']),
    ),
  );
}

/// `parentSessionId`（可选，**别名形式**）。
///
/// 连接器对根会话**不给这个键**，并且显式不为 `undefined` / 空串建别名
/// （`connector/src/handlers.ts:728-736`）—— 所以"在且是空串"**只可能来自漂移**，
/// 计一次数（空串当 sid 会让父级查名字永远落空，`handlers.ts:726-727` 记着这条）。
String? _parentSidOf(Map<Object?, Object?> row) {
  final value = row['parentSessionId'];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  WireDiagnostics.report(_kSessionList, 'parentSessionId 在但不是可用的非空字符串：$value');
  return null;
}

/// `cwd`（可选，工作区目录）。
///
/// 连接器原样透传宿主的 `cwd`（`connector/src/handlers.ts:760`、`dsh/sessions.ts:330`），
/// 所以**空串只可能意味着"没有目录"**，不是漂移 ⇒ 按缺席处理、**不计数**
/// （这里与 `parentSessionId` 的处理不同：那个键的空串是生产侧明确排除的，这个不是）。
/// 空串会让"按工作区挑靶子"静默匹配失败，所以一律降级成 `null`。
String? _cwdOf(Map<Object?, Object?> row) {
  final value = row['cwd'];
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  WireDiagnostics.report(_kSessionList, 'cwd 不是字符串：$value');
  return null;
}

/// 行顶层的 `model`（可选）。形状是 DSH 的 `ModelSelection`
/// （`{provider, model, reasoningEffort?}`，`connector/src/dsh/models.ts:70-76`）。
ModelRef? _optionalModelOf(Object? raw) {
  if (raw == null) return null;
  final ref = _modelRefOf(raw);
  if (ref == null) {
    WireDiagnostics.report(
      _kSessionList,
      'model 在但不是 {provider, model} 形状：$raw',
    );
  }
  return ref;
}

/// **信封** `{kind, asOfSeq, values}` → `values`。
///
/// **这不是扁平 map**：`session.projections` 的应答才是扁平 `values`（第 3 批）。
/// `kind` / `asOfSeq` 手机不用，所以不声明（少一个要维护的键）。
/// `values` 不是 Map ⇒ 四个投影字段全降级 + **计数一次**（信封本身坏了，只报一次，不报四次）。
Map<Object?, Object?>? _envelopeValuesOf(Object? raw) {
  if (raw == null) return null;
  if (raw is Map) {
    final values = raw['values'];
    if (values is Map) return values;
  }
  WireDiagnostics.report(
    _kSessionList,
    'projections 在但不是信封 {kind, asOfSeq, values}：$raw',
  );
  return null;
}

/// `values.title`（列表标题，`connector/src/dsh/sessions.ts:125-131`）。
///
/// **缺席 / `null` / 空串都是正常**：未命名会话本来就没有标题，界面显示「未命名」
/// （`SessionSummary.displayTitle`），所以这些情形**不计数**。
/// 在但不是字符串才是漂移（计数一次、按空标题处理）。
String _titleOf(Map<Object?, Object?>? values) {
  final title = values?['title'];
  if (title == null) return '';
  if (title is String) return title;
  WireDiagnostics.report(_kSessionList, 'values.title 不是字符串：$title');
  return '';
}

/// `values.modelSelection` → `next ?? lastUsed`。
///
/// **`next ?? lastUsed` 与 DSH 的线格式逐字一致**
/// （`packages/api/session-controller/src/model-selection-projection.ts:65`：
/// `view: state => ({lastUsed, next: state.pending ?? state.lastUsed})`），
/// 与连接器的 `modelOf` 也是同一条（`connector/src/dsh/models.ts:92-101`）。
///
/// **只对"这一层的类型"计数**：`modelSelection` 是 Map 但里面 `lastUsed` / `next` 都是 `null`
/// 是**正常**（新会话、投影还没落），所以不再往下计 —— 往下计会把正常态报成漂移。
ModelRef? _modelSelectionOf(Map<Object?, Object?>? values) {
  final selection = values?['modelSelection'];
  if (selection == null) return null;
  if (selection is! Map) {
    WireDiagnostics.report(
      _kSessionList,
      'values.modelSelection 不是对象：$selection',
    );
    return null;
  }
  return _modelRefOf(selection['next'] ?? selection['lastUsed']);
}

/// `{provider, model, reasoningEffort?}` → [ModelRef]；认不出返回 `null`（**不计数**，
/// 由调用方按"这一层的类型对不对"决定要不要响）。
///
/// 缺 `provider` / `model` 就当没有 —— 硬填空串会让界面显示一个空的模型名。
ModelRef? _modelRefOf(Object? raw) {
  if (raw is! Map) return null;
  final provider = raw['provider'];
  final model = raw['model'];
  if (provider is! String || provider.isEmpty) return null;
  if (model is! String || model.isEmpty) return null;
  final effort = raw['reasoningEffort'];
  return ModelRef(
    provider: provider,
    model: model,
    reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
  );
}
