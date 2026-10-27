/// **会话面**（`session.*`）的**唯一入口**：发请求 + 解码。方法名、参数形状、应答字段只在这里。
///
/// ## 形状的出处（不是猜的）
///
/// - **`session.list`**：应答 `{sessions: [...]}`（`connector/src/handlers.ts:738-770`）。
///   **行是连接器自造的，不是宿主形状** —— 逐字段构造、不 spread，`dshSessionId` 绝不过线
///   （`handlers.ts:719-720` 的原话）。所以形状出处是**连接器**，不是 `packages/...`。
///   行的 `.projections` 是**信封** `{kind, asOfSeq, values}`
///   （`connector/src/dsh/sessions.ts:333-341` 逐键重建、`handlers.ts:766-768` 过线）。
///   **这不是扁平 map** —— 同名方法 `session.projections` 的应答才是扁平 `values`
///   （`connector/src/dsh/projections.ts:68-72` 拆信封、`:94` 返回）。同一个名字两种形状、
///   读错的表现是静默空值：金样里两条并存就是为了让读错的人**红**。
/// - **`session.create`**：`{sid}`（+ 条件字段 `agentPreset`），`connector/src/handlers.ts:684-714`。
/// - **`session.select-model`**：`{selected: {provider, model}}`（`handlers.ts:662-676`）。
/// - **`session.modelCatalog`**：`{available: bool}` 或 `{available: true, catalog: {...}}`
///   （`handlers.ts:776-782`）；目录本体是 DSH 的 `buildModelCatalog` 形状
///   （`packages/api/session-controller/src/catalog.ts:20-72`），由 `model/model_catalog.dart` 解析。
/// - **`session.cancel`** / **`session.updateQueue`** / **`session.prompt`**（及
///   **`subagent.prompt`**）：**应答今天没有任何消费者**（`cancel` / `updateQueue` 连返回形态
///   都不判；`prompt` 直接 `call<void>`，应答里的 `{accepted}` 从来没读过）。
///   按纪律这里**只搬调用**（方法名与参数形状是协议知识），**不造 decoder**
///   —— 造一个没人读的 decoder 等于给"我们校验过了"的假象。
///   **将来有人开始读它们的应答，那一刻才加 `read*`**（`session.prompt` 的应答若要用上，
///   就是在这里加 `readPromptReceipt`）。
///
/// ## 必填 / 可选的分界看生产方式，不看名字
///
/// `handlers.ts:740-744` **无条件写出**的五个键（`sid`/`updatedAt`/`running`/`blank`/`subagent`）
/// 缺失 = 漂了 ⇒ 整行丢 + 计数；被 `...(cond ? {} : …)` 包住的四个键（`parentSessionId`
/// `:750`、`model` `:754-759`、`cwd` `:760`、`projections` `:766-768`）缺失 = 正常 ⇒ `null`。
/// 字段级语义的唯一实现在 `wire/fields.dart`（这个文件只声明"哪个键属于哪一档"）。
///
/// ## 失败语义
///
/// 信封错 ⇒ [WireBad]（整个列表读不出来）；一条坏行 ⇒ 丢那一条 + 计数；
/// 可选字段读不出 ⇒ 该字段 `null` + 计数（**不丢整行**：丢整行会让会话从列表消失，
/// 比空标题坏得多）。
///
/// Note: 取舍、批次与代价见 `.agents/notes/implemented/2026-10-25-wire-golden-and-session-list.md`
/// 与 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/job.dart' show parseSubagentCatalogValue;
import '../../core/sync_client.dart';
import '../../model/chat_item.dart';
import '../../model/model_catalog.dart'
    show ModelCatalog, parseModelCatalogValue;
import '../../model/session_stats.dart' show parseTokenUsage;
import '../../model/subagent.dart' show parseSubagentTiming;
import '../fields.dart';
import '../reading.dart';
import '../values.dart';

/// 消费方一次拿齐"三态内核 + 字段内核 + 会话面解码"（与 `wire/events.dart` 同一条：
/// 全 app 只有一套失败语义）。
export '../fields.dart';
export '../reading.dart';

// 每个方法名在整个仓库里只出现在这个文件（预算门禁扫 `data/` 与 `ui/`）。
const String _kList = 'session.list';
const String _kCreate = 'session.create';
const String _kFork = 'session.fork';
const String _kSelectModel = 'session.select-model';
const String _kCancel = 'session.cancel';
const String _kUpdateQueue = 'session.updateQueue';
const String _kPrompt = 'session.prompt';
const String _kModelCatalog = 'session.modelCatalog';

// ---------------------------------------------------------------------------
// 发请求（唯一入口）+ 解码
// ---------------------------------------------------------------------------

/// 发请求 + 解码，**`session.list` 的唯一调用口**。
///
/// 收 [SyncClient]（`app/lib/core/sync_client.dart:136-144` 的既有端口）而**不新造
/// `RpcCaller` 之类的平行抽象**：端口本来就有，再造一个只是重复。
/// 依赖方向也是对的：适配器（`wire/rpc`）依赖端口（`SyncClient`）。
///
/// 形状错的计数与出声走 `valueOrReport`（唯一出口）；`null` 只剩"读不出来"一个含义。
Future<List<SessionSummary>> loadSessionList(SyncClient client) async {
  final result = await client.call<Object?>(_kList, const {});
  return valueOrReport(readSessionList(result), _kList) ?? const [];
}

/// 建会话，回新的 `sid`（读不出来 ⇒ `null` + 计数；调用方据此**大声失败**）。
///
/// 参数形状出处 `connector/src/handlers.ts:684-701`：`workspaceId` / `cwd` / `agentPreset`
/// 都是可选的字符串，手机只发前两个中的一个 + 预设。
Future<String?> createSession(
  SyncClient client, {
  String? workspaceId,
  String? agentPreset,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kCreate, {
    // 显式 `if` 而不是 null-aware element（`?key: value`）：后者的 key 取的是
    // **值的字符串形式**而不是标识符（2026-10-15 实测展开成 `high: high`）。
    // `dart analyze` 会反过来建议改过去（`use_null_aware_elements`），别听。
    // ignore: use_null_aware_elements
    if (workspaceId != null) 'workspaceId': workspaceId,
    // ignore: use_null_aware_elements
    if (agentPreset != null) 'agentPreset': agentPreset,
  }, requestId: requestId);
  return valueOrReport(readCreatedSid(result), _kCreate);
}

/// 在一轮的收口处**分支**，回子会话的 `sid`（读不出来 ⇒ `null` + 计数）。
///
/// 坐标是**该轮收口事件的序号**（桌面 `forkAt(turn.end.seq)`，`apply.ts:299-305`），
/// 不是轮号也不是路径；`atSeq` 缺省时宿主取"最近一个已完成轮次"。
/// 标题后缀由连接器照 Web 客户端服务层做（宿主 fork 没有这个参数）——
/// 手机不需要知道它。
Future<String?> forkSession(
  SyncClient client, {
  required String sid,
  int? atSeq,
}) async {
  final result = await client.call<Object?>(_kFork, {
    'sid': sid,
    // ignore: use_null_aware_elements
    if (atSeq != null) 'atSeq': atSeq,
  });
  return valueOrReport(readForkedSid(result), _kFork);
}

/// `session.fork` 的应答 `{sid}`（子会话的**别名**）。
WireReading<String> readForkedSid(Object? result) =>
    readObject(_kFork, result, (fields) => fields.requireNonEmptyString('sid'));

/// 切模型，回电脑侧**实际生效**的那一对（`{selected: {provider, model}}`）。
///
/// 读不出来 ⇒ `null` + 计数，由调用方决定怎么显示（它手里有"刚发出去的那个值"）。
Future<ModelRef?> selectModel(
  SyncClient client, {
  required String sid,
  required String provider,
  required String model,
  String? reasoningEffort,
  required String requestId,
}) async {
  final result = await client.call<Object?>(_kSelectModel, {
    'sid': sid,
    'provider': provider,
    'model': model,
    // ignore: use_null_aware_elements
    if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
  }, requestId: requestId);
  return valueOrReport(readSelectedModel(result), _kSelectModel);
}

/// 打断当前轮次（**应答不读**：见文件头那一节）。
Future<void> cancelSession(SyncClient client, {required String sid}) =>
    client.call<void>(_kCancel, {'sid': sid});

/// 变异一个排队项（**应答不读**：见文件头那一节）。
///
/// `action` 的三种形状由调用方拼（`connector/src/handlers.ts:627-651` 的校验说明
/// `edit` 只收纯文本块）；这里只负责方法名、`sid`/`itemId` 这两个键与幂等键。
Future<void> updateQueueAction(
  SyncClient client, {
  required String sid,
  required String itemId,
  required Map<String, Object?> action,
  required String requestId,
}) => client.call<void>(_kUpdateQueue, {
  'sid': sid,
  'itemId': itemId,
  'action': action,
}, requestId: requestId);

/// 给会话发一条人写的消息（**应答不读**：`{accepted}` 今天没有人消费）。
///
/// 参数形状出处 `connector/src/handlers.ts:585-599`：`content` 是非空的内容块数组，
/// `mode` 只有 `queue` / `steer` 两个取值。
Future<void> sendPrompt(
  SyncClient client, {
  required String sid,
  required List<Object?> content,
  required String mode,
  required String requestId,
}) => client.call<void>(_kPrompt, {
  'sid': sid,
  'content': content,
  'mode': mode,
}, requestId: requestId);

/// 模型目录：`{available: false}` 或 `{available: true, catalog: {...}}`。
///
/// `available: false` 是**电脑侧的明说**（"目录拿不到"），不是形状错 ⇒ `WireOk(null)`；
/// 界面显示"拿不到目录"而不是摆一个空列表（`handlers.ts:778-780` 的注释）。
Future<ModelCatalog?> loadModelCatalog(SyncClient client) async {
  final result = await client.call<Object?>(_kModelCatalog, const {});
  return valueOrReport<ModelCatalog?>(readModelCatalog(result), _kModelCatalog);
}

// ---------------------------------------------------------------------------
// 纯解码（给回放用例与"已经拿到应答"的调用方：不收 client，用例里不启传输）
// ---------------------------------------------------------------------------

/// `session.list` 的应答。**裸数组不算**：连接器从来只回 `{sessions: [...]}`
/// （`connector/src/handlers.ts:738`）；早先那份"两种都认"的写法让"认不出就必须留声"
/// 永远不成立 —— 现在裸数组 ⇒ [WireBad]（空列表 + 计数 1）。
WireReading<List<SessionSummary>> readSessionList(Object? result) =>
    readObjectList(
      result,
      method: _kList,
      key: 'sessions',
      build: _buildSessionRow,
    );

/// 一行。缺 `sid` / 恒发键 ⇒ [WireBad]（整行丢 + 计数）；
/// 四个可选键读不出 ⇒ 该字段降级为 `null` + 计数（**不丢整行**）。
///
/// 行级 decoder **不产 [WireSkip]**：每一行都该是一条会话，没有"不是我要的行"这种情形。
WireReading<SessionSummary> readSessionRow(Object? row) =>
    readObject(_kList, row, _buildSessionRow);

/// `session.create` 的应答：`{sid}`（`connector/src/handlers.ts:702-714`）。
///
/// `sid` 缺失**必须大声失败**：新建会话拿不到 `sid` 就等于没建成，而"看起来建成了"
/// 是 2026-10-17 真机抓到的那次（hero 上提示"新建会话没有回 sid"）。
WireReading<String> readCreatedSid(Object? result) => readObject(
  _kCreate,
  result,
  (fields) => fields.requireNonEmptyString('sid'),
);

/// `session.select-model` 的应答：`{selected: {provider, model}}`。
///
/// `reasoningEffort` **不声明**：手机不从回执里读它（界面显示的是"下一次"的模型名，
/// 推理等级在清单行的投影提示里）。少声明一个键就少一处要维护的漂移面。
WireReading<ModelRef> readSelectedModel(Object? result) =>
    readObject(_kSelectModel, result, (fields) {
      final selected = WireFields(fields.requireMap('selected'), _kSelectModel);
      return ModelRef(
        provider: selected.requireNonEmptyString('provider'),
        model: selected.requireNonEmptyString('model'),
      );
    });

/// `session.modelCatalog` 的应答：`{available, catalog?}`。
///
/// **目录本体不进这个文件**：它是 DSH 的 `buildModelCatalog` 形状
/// （`packages/api/session-controller/src/catalog.ts:20-72`），解析器仍在
/// `model/model_catalog.dart`（与 `parseTokenUsage` 同一条：投影值/目录值的解析住在 `model/`，
/// `wire/` 只负责"从哪一层取"）。
WireReading<ModelCatalog?> readModelCatalog(Object? result) =>
    readObject(_kModelCatalog, result, (fields) {
      final available = fields.requireBool('available');
      if (!available) return null;
      final catalog = parseModelCatalogValue(fields.requireMap('catalog'));
      if (catalog == null) {
        throw const WireFieldError('catalog 认不出（session.modelCatalog）');
      }
      return catalog;
    });

// ---------------------------------------------------------------------------
// 行的构造（一个方法一个 builder，字段级语义全在 wire/fields.dart）
// ---------------------------------------------------------------------------

SessionSummary _buildSessionRow(WireFields fields) {
  // ---- 恒发键：`handlers.ts:740-744` 无条件写出，缺了就是漂了 ----
  final sid = fields.requireNonEmptyString('sid');
  final updatedAt = fields.requireInt('updatedAt');
  final running = fields.requireBool('running');
  final blank = fields.requireBool('blank');
  final subagent = fields.requireBool('subagent');

  // ---- 可选键：缺失是正常（生产侧按条件展开），在但读不出才计一次数 ----
  // `parentSessionId`：连接器对根会话**不给这个键**，并且显式不为 `undefined` /
  // 空串建别名（`handlers.ts:728-736`）—— 所以空串只可能来自漂移。
  final parentSid = fields.optionalAlias('parentSessionId');
  // `cwd`：连接器原样透传宿主的 cwd（`handlers.ts:760`、`dsh/sessions.ts:330`），
  // 所以空串只可能意味着"没有目录"⇒ 按缺席处理、**不计数**。
  final cwd = fields.optionalNonEmptyString('cwd');
  // `model`：行顶层那份来自**活 agent**（`connector/src/dsh/models.ts` 的 `modelOf`），
  // 子会话取不到 ⇒ 整键缺席。所以它**不是**恒发键（`handlers.ts:754-759`）。
  final model = modelRefOf(fields.optionalMap('model'), fields);

  final values = fields.envelopeValues('projections');
  final modelSelection = modelSelectionOf(values?['modelSelection'], fields);

  return SessionSummary(
    sid: sid,
    title: _titleOf(values, fields),
    updatedAt: updatedAt,
    running: running,
    blank: blank,
    subagent: subagent,
    parentSid: parentSid,
    // 投影提示优先，行顶层兜底：子会话的 `model` 恒缺席，只认顶层会让
    // 子智能体页面的输入栏显示「未选择」（`chat_item.dart:852-862` 记着这条）。
    model: modelSelection ?? model,
    cwd: cwd,
    // 两个投影值解析器仍住 `model/`：它们是**投影值**的解析，这里只管"从信封的哪一层取"。
    subagentTiming: parseSubagentTiming(values?['subagentTiming']),
    tokenUsage: parseTokenUsage(values?['tokenUsage']),
    // **父行的直接子目录**：`subagentCatalog` 是 summary 键（默认携带），连接器原样透传。
    // 桌面据此在客户端算"几个子智能体在跑"（`tree.ts:381-386`），手机同一条；
    // 少了这一步，连接瞬间只能进子智能体页才看得见后台任务。
    subagents: parseSubagentCatalogValue(values?['subagentCatalog']),
  );
}

/// `values.title`（列表标题，`connector/src/dsh/sessions.ts:125-131`）。
///
/// **缺席 / `null` / 空串都是正常**：未命名会话本来就没有标题，界面显示「未命名」
/// （`SessionSummary.displayTitle`），所以这些情形**不计数**。
/// 在但不是字符串才是漂移（计数一次、按空标题处理）。
String _titleOf(Map<Object?, Object?>? values, WireFields fields) {
  final title = values?['title'];
  if (title == null) return '';
  if (title is String) return title;
  fields.report('values.title 不是字符串：$title');
  return '';
}

/// `values.modelSelection` → `next ?? lastUsed`。
///
/// 解析器只有一份：`wire/values.dart` 的 [modelSelectionOf]（与投影面共用）。
