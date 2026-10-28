/// 任务输出帧的类型化形状（契约 §5.3 的 `job` 帧、§7 的 `job.*` 方法）。
///
/// ## 为什么从 `(帧头, 明文)` 元组换成类型
///
/// 原来 `SyncClient.jobFrames` 交出 `List<(Map, String)>` —— 一个**没有任何
/// 消费者**的死 API(静态审查确认:接口、实现、测试三处都没有人读它),而任务面板
/// 接不上正是因为它:UI 要自己解析明文 JSON,那等于让"帧里是什么"有第二个答案。
///
/// 换成类型之后:
/// - 解析只发生一次(在 `sync_client_impl`,那里本来就有明文);
/// - UI 拿到的是 `sealed class`,漏一种 `switch` 编译期就红;
/// - 形状与连接器侧 `protocol/job-output.ts` 的 `JobOutputFrame` 一对一。
///
/// ## 为什么是独立的帧类型而不是复用 `live`
///
/// `live` 的 `rev` 被 assistant 流占满,读法是 `rev == last + 1` 追加、跳跃即丢弃;
/// 而任务输出的推进量是**输出字节偏移**(会跳号)。塞进同一个字段会让手机把
/// assistant 的文本丢掉 —— 那是 `credit` 那一处已经否掉的做法(§4.3)。
library;

import 'dart:convert';

/// 一个后台任务给手机看的那一行（连接器 `JobRowView` 的逐字对应）。
class JobRow {
  const JobRow({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    required this.startedAt,
    required this.outputTotal,
    this.progress,
    this.detail,
    this.finishedAt,
    this.sid,
  });

  final String id;

  /// 命令或子智能体名（等宽字体显示）。
  final String label;

  /// `pwsh` / `bash` / …
  final String kind;

  /// `running` / `stopping` / `completed` / `killed` / `failed`。
  final String status;

  final int startedAt;
  final int? finishedAt;

  /// 已产出的总字节数；正文走输出帧。
  final int outputTotal;

  final String? progress;
  final String? detail;

  /// 这个任务属于哪个会话（**手机见的 sid**）。
  ///
  /// 连接器在帧上盖的（`connector/src/job-subscriptions.ts` 的 `transform`）——
  /// `job` 帧本身不带会话，手机此前只能猜"归哪个桶"，猜错的后果是
  /// "正在看的会话不显示后台任务 chip、别的会话凭空多一个"
  /// （2026-10-15 真机：先开 A 再开 B，B 里新起的任务被归到 A）。
  ///
  /// `null` = 这帧没有出处（老连接器 / 无主任务）：调用方据此决定**要不要**猜，
  /// 而不是把空串当键。
  final String? sid;

  /// 还在跑（含正在停）—— UI 据此分"实时 / 已结束"两组。
  bool get isLive => status == 'running' || status == 'stopping';

  /// 人类可读状态。**与 DSH 的状态词一一对应**,不自己造第二套说法。
  ///
  /// DSH 的 `JobStatus` 是封闭五档（`packages/jobs/jobs/src/view.ts:19`），
  /// 所以正常数据一定命中前五支。第六支只服务**版本漂移**：那时刻意**不回显原词**
  /// —— 回显就等于把宿主的状态字（英文）直接画进中文句子，而桌面从不打印状态词，
  /// 它只把状态映射成文案或 `data-state`（`ui-jobs/src/client/JobListAction.tsx:148-150`、
  /// `ui-primitives/src/TerminalBlock.tsx:153`）。
  String get statusText => switch (status) {
    'running' => '进行中',
    'stopping' => '停止中',
    'completed' => '已完成',
    'killed' => '已停止',
    'failed' => '失败',
    _ => '状态未知',
  };
}

/// 合并一条任务行：**终态单向**。
///
/// 同一个 `jobId` 是一次运行，不会复活（`killed` / `completed` / `failed`
/// 之后不会再回到 `running`）。所以只有一种情形要挡：**已有行已结束、来的是 live**
/// —— 留已有行。其余方向照收（新的终态、更新的 live 都是更新）。
///
/// ## 为什么是一条规则而不是两处判据
///
/// `job.list` 是**请求**、`job` 是**推送**，两者会赛跑（2026-10-25 实测：
/// 快照请求还没回来，推送先说任务完成了，旧快照把它盖回 `running`，面板永远转）。
/// 同一个不变量出现在两条写路径上，就必须只有一份实现 —— 否则下一次只会修好一条。
///
/// Note: 取舍见 `.agents/notes/implemented/2026-10-26-wire-review-fixes.md`（第 2 批）。
JobRow mergeJobRow(JobRow? existing, JobRow incoming) {
  if (existing == null) return incoming;
  if (!existing.isLive && incoming.isLive) return existing;
  return incoming;
}

/// 把一次 `job.list` 快照并进桶里：逐行套 [mergeJobRow]。
///
/// **快照里没有的行丢弃**：`job.list` 给的是这个会话的全集，保留幽灵行会让
/// "电脑侧已经没有了"的任务一直挂在面板上。丢弃只发生在"快照确实成功"时
/// （解码失败时调用方不会走到这里，见 `refreshJobs`）。
List<JobRow> mergeJobSnapshot(List<JobRow> existing, List<JobRow> incoming) {
  final byId = {for (final row in existing) row.id: row};
  return [for (final row in incoming) mergeJobRow(byId[row.id], row)];
}

/// 一块输出。偏移 `at` **永不移动**。
class JobChunk {
  const JobChunk({
    required this.at,
    required this.text,
    this.channel,
    this.gapBefore = false,
  });

  final int at;
  final String text;

  /// `stdout` / `stderr` / `log`。
  final String? channel;

  /// 前面有字节被淘汰了 —— 必须显式提示，**不许静默拼接**。
  final bool gapBefore;
}

/// 一条 `job` 帧。四种载荷照连接器一对一。
sealed class JobFrame {
  const JobFrame(this.jobId);

  final String jobId;
}

/// 订阅刚开：带上任务行与"第一帧 output 从哪继续"。
class JobOpened extends JobFrame {
  const JobOpened({
    required String jobId,
    required this.row,
    required this.from,
  }) : super(jobId);

  final JobRow row;
  final int from;
}

/// 一批输出。
class JobOutput extends JobFrame {
  const JobOutput({
    required String jobId,
    required this.chunks,
    required this.next,
    this.lossy = false,
  }) : super(jobId);

  final List<JobChunk> chunks;

  /// 读完这一帧后从哪个偏移继续。
  final int next;

  /// 请求的偏移与 `chunks` 之间已有字节被淘汰。
  final bool lossy;
}

/// 任务状态变了（终态也会来一条）。
class JobStatus extends JobFrame {
  const JobStatus({required String jobId, required this.row}) : super(jobId);

  final JobRow row;
}

/// 订阅中断（宿主流出错，或出帧失败）。
///
/// **宿主没有这一帧**：它的 `follow` 出错就是抛。通道补这一条是为了让手机
/// 把"实时输出流中断"显式渲染出来。收到它只表示这段订阅结束了，
/// 任务本身可能还在跑。
class JobError extends JobFrame {
  const JobError({required String jobId, required this.message}) : super(jobId);

  final String message;
}

/// 一个子智能体在**目录里**的那一行（DSH 的 `subagentCatalog` 投影）。
///
/// 投影的 view 形状（已核实 `packages/subagent/subagent/src/catalog.ts:77-94,111-131`）：
/// 数组，每项 `{ id, createdAt, mode, label? }`，`mode` ∈
/// `one-shot` / `continuable` / `external` / `unknown`。
/// **不翻译 mode**：它与 DSH 逐字一致，翻译一层就多一处会漂移的地方。
///
/// ## 这里只有**目录事实**，没有状态
///
/// 2026-10-21 之前这里还有 `status` / `isLive` / `finishedAt` /
/// `statusText`，全部**由 `mode` 推**：`one-shot` ⇒ `completed`，其余 ⇒ `running`。
/// 那是两个维度被合成一个：`mode` 说的是"能不能续聊"（**不随时间变**），
/// 而"此刻跑没跑"来自**子会话自己**的 `running`
/// （Web 的判据：`SubagentHeaderLineage.tsx:471-475` 用
/// `statuses.get(entry.id)?.running ?? summaries[entry.id]?.running`）。
/// 后果是可续聊的子会话跑完后，面板与顶栏仍显示「正在运行」、分组永远停在「进行中」。
///
/// 所以事实留在这里，运行态视图在 `model/subagent.dart` 的 `SubagentNode`
/// —— 它才拿得到子会话的时间线与 token。
/// 布局与三态的因果见 `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
class SubagentRow {
  const SubagentRow({
    required this.id,
    required this.createdAt,
    required this.mode,
    this.label,
  });

  final String id;

  /// 电脑侧的创建时间（毫秒）。**不是时长的起点** —— 时长是
  /// `subagentTiming` 累加的"活跃轮次时长"（见 `SubagentTiming`）。
  final int createdAt;

  /// `one-shot` / `continuable` / `external` / `unknown`。
  final String mode;

  /// 人类可读名字；缺了就靠 id。
  final String? label;

  String get displayLabel => (label == null || label!.isEmpty) ? id : label!;

  /// 外部任务：DSH 不给它开子会话（`SubagentHeaderLineage.tsx:279-287` 的
  /// `open()` 第一行 `if (external) return`），也不能展开。
  bool get isExternal => mode == 'external';

  /// 行第二段的 mode 词。**逐字照 DSH 的 zh 词典**
  /// （`ui-subagent/src/client/locales.ts:26-29`）：
  /// `external` → 外部任务 / `unknown` → 模式未知 / `one-shot` → 一次性 /
  /// 其余 → 可继续。
  String get modeText => switch (mode) {
    'external' => '外部任务',
    'one-shot' => '一次性',
    'continuable' => '可继续',
    _ => '模式未知',
  };
}

/// 解 `subagentCatalog` 投影的应答：`{ subagentCatalog: [{id, createdAt, mode, label?}] }`。
///
/// **认不出返回空表，不猜**：一个形状不对的条目拨不出去也显示不出，
/// 而硬填会让"没有子智能体"和"投影形状变了"看起来一模一样。
List<SubagentRow> parseSubagentCatalog(Object? raw) {
  if (raw is! Map) return const [];
  return parseSubagentCatalogValue(raw['subagentCatalog']);
}

/// 解析**裸的** `subagentCatalog` 值。
///
/// `session.list` 行的 `values.subagentCatalog` 就是这一项本身（summary 键默认携带，
/// `session/session-projection/src/index.ts:109-115,367`；连接器原样透传），
/// 所以两个入口必须共用这一份解析 —— 分两份写就会漂。
List<SubagentRow> parseSubagentCatalogValue(Object? list) {
  if (list is! List) return const [];
  final out = <SubagentRow>[];
  for (final entry in list) {
    if (entry is! Map) continue;
    final id = entry['id'];
    final createdAt = entry['createdAt'];
    final mode = entry['mode'];
    if (id is! String || id.isEmpty) continue;
    if (createdAt is! num || mode is! String) continue;
    final label = entry['label'];
    out.add(
      SubagentRow(
        id: id,
        createdAt: createdAt.toInt(),
        mode: mode,
        label: label is String && label.isNotEmpty ? label : null,
      ),
    );
  }
  return out;
}

/// 解析 `job` 帧的明文载荷（连接器 `JobOutputFrame` 的逐字对应）。
///
/// **认不出就抛**：一帧解不开还当成功，UI 会显示一块空白输出，
/// 而真因是形状对不上。抛出去由调用方决定怎么呈现（`sync_client_impl`
/// 把它转成 [JobError]，任务面板于是显示"这一帧没解出来"）。
JobFrame parseJobFrame(String plaintext) {
  final Object? decoded = jsonDecode(plaintext);
  if (decoded is! Map) throw const FormatException('任务帧载荷必须是 JSON 对象');
  final jobId = decoded['jobId'];
  if (jobId is! String || jobId.isEmpty) {
    throw const FormatException('任务帧缺少 jobId');
  }
  final kind = decoded['kind'];
  switch (kind) {
    case 'opened':
      return JobOpened(
        jobId: jobId,
        row: _parseRow(decoded['job'], jobId),
        from: _requireInt(decoded['from'], 'from'),
      );
    case 'output':
      final raw = decoded['chunks'];
      if (raw is! List) throw const FormatException('output 帧缺少 chunks 数组');
      return JobOutput(
        jobId: jobId,
        chunks: [
          for (final entry in raw)
            if (entry is Map)
              JobChunk(
                at: _requireInt(entry['at'], 'chunk.at'),
                text: entry['text'] is String ? entry['text'] as String : '',
                channel: entry['channel'] is String
                    ? entry['channel'] as String
                    : null,
                gapBefore: entry['gapBefore'] == true,
              ),
        ],
        next: _requireInt(decoded['next'], 'next'),
        lossy: decoded['lossy'] == true,
      );
    case 'status':
      return JobStatus(jobId: jobId, row: _parseRow(decoded['job'], jobId));
    case 'error':
      return JobError(
        jobId: jobId,
        message: decoded['message'] is String
            ? decoded['message'] as String
            : '未知原因',
      );
    default:
      throw FormatException('不认识的任务帧 kind：$kind');
  }
}

JobRow _parseRow(Object? raw, String jobId) {
  if (raw is! Map) throw const FormatException('任务帧的 job 必须是对象');
  return JobRow(
    id: raw['id'] is String ? raw['id'] as String : jobId,
    kind: raw['kind'] is String ? raw['kind'] as String : '',
    label: raw['label'] is String ? raw['label'] as String : '',
    status: raw['status'] is String ? raw['status'] as String : 'running',
    startedAt: _requireInt(raw['startedAt'], 'startedAt'),
    outputTotal: _requireInt(raw['outputTotal'], 'outputTotal'),
    progress: raw['progress'] is String ? raw['progress'] as String : null,
    detail: raw['detail'] is String ? raw['detail'] as String : null,
    finishedAt: raw['finishedAt'] is int ? raw['finishedAt'] as int : null,
  );
}

int _requireInt(Object? value, String field) {
  if (value is! int) throw FormatException('$field 必须是整数');
  return value;
}
