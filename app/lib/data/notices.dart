/// 提醒簇里那三件**原来没有主人**的事：一条通知的**身份**、**该提醒什么**、
/// **已经贴上去的是哪一份**。
///
/// ## 它为什么从 `AppModel` 搬出来
///
/// 这三件事原先散在 `app_model.dart` 的 3005–3260 那段里，症状是"同一件事
/// 反复重新表达"：
///
/// | 事实 | 原来几处 |
/// |---|---|
/// | 通知 id = `noticeIdOf(keyOf(kind, id))`，键带电脑前缀 | **6 处**（审批 ×3、提问、任务、整轮完成）|
/// | "撤一条已经贴上去的" | **3 处**（应答失效、应答抛错、差集收尾）+ `dispose` 一处 |
/// | "哪些事值得提醒"（审批 / 提问 / 任务窗口 / 整轮完成） | 1 处，但埋在一个 5000 行的类中段 |
///
/// 这就是 `tools.md` 里那条判据的形状：**拆分的信号是重复的清单与缺失的所有者**。
/// 搬出来的不是"另一个 AppModel 片段"，而是这三件事实的唯一所有者。
///
/// ## 边界（写在这里，免得下次又搬回去）
///
/// - **不认识端口**：不调 `NotifyPort.show` / `cancel`，只回答"该贴哪些、该撤哪些"，
///   由调用方去贴去撤（同 `JobBook` 不订阅、不 kill 那条）。
/// - **不认识 `AppModel`**：需要会话条目 / 任务行 / 未读标记的地方由调用方**传函数**。
///   这样它不需要知道"条目存在哪个 store、任务存在哪个书"。
/// - **不发通知**（`notifyListeners` / 平台端口都不碰）。
/// - **不落盘**：已贴的那一批是派生状态，杀 App 即丢（与"完成绿点"同一条理由）。
///
/// 决策与代价见 `.agents/notes/implemented/2026-11-12-notice-board-extraction.md`。
library;

import '../core/job.dart';
import '../core/notify.dart';
import '../model/chat_item.dart';

/// 后台任务结束的**提醒窗口**：只有在这个时间窗内结束的任务才贴通知。
///
/// 不设窗口的后果很具体：冷启动时任务表里全是历史终态任务，一次重算就把
/// 几十条"某某任务跑完了"贴上去 —— 那些事早就过去了，用户只会关掉通知权限。
/// 30 分钟与"这一轮刚跑完"对齐（参考实现 `refs/remotes/pr/8:a4a9775` 同一档）。
const Duration kJobNoticeWindow = Duration(minutes: 30);

/// 通知 id 的键：**带电脑前缀**。
///
/// `sid` 是电脑侧独立分配的不透明别名，条目 id 同样是各电脑自己生成的 ——
/// 两台撞名完全可能。不带前缀时同一条审批在两台上算出同一个 `noticeIdOf`，
/// 于是撤掉 B 的那条会把 A 的也撤掉（`cancel(id)` 只按 id 认人）。
///
/// 没有电脑身份时（未配对 / 单测）保持平铺形状：那种状态下不存在"哪一台"，
/// 与 `meta` 表里 `host.<field>` 的平铺键同一条理由（`docs/subsystems/ui-state.md` §2）。
String noticeKeyOf({
  required String hostId,
  required String kind,
  required String id,
}) => hostId.isEmpty ? '$kind:$id' : '$hostId|$kind:$id';

/// 一条通知的 id（身份 + 内容哈希）。**唯一算法**：撤的时候要能凭同一件事找回它。
int noticeIdFor({
  required String hostId,
  required String kind,
  required String id,
}) => noticeIdOf(noticeKeyOf(hostId: hostId, kind: kind, id: id));

/// 审批那条通知的 id（应答失效时要撤它）。
int approvalNoticeId({required String hostId, required String itemId}) =>
    noticeIdFor(hostId: hostId, kind: 'approval', id: itemId);

/// 期望的通知集合 —— **完全从既有事实派生**。
///
/// 四类提醒的判据全在这里，一类一段：
///
/// | 类 | 判据 | 按钮 |
/// |---|---|---|
/// | 审批 | 本地 `ApprovalItem` 未决 | 「允许一次 / 拒绝」（DSH 的 outcome 值）|
/// | 提问 | `ask_user_question` 的 `tool/call` 还没有 `tool/result` | 不给按钮 |
/// | 后台任务 | 落了终态且 `finishedAt` 在 [kJobNoticeWindow] 内 | 不给按钮 |
/// | 整轮跑完 | `completionUnreadOf(sid)`（绿点的同一个判据） | 不给按钮 |
///
/// 入参全都是"既有事实"，没有一件是本文件自己记的 —— 这也是它能在
/// `AppModel` 之外被单测的原因（构造几个事实就能断言"该提醒什么"）。
List<AttentionNotice> desiredNotices({
  /// 电脑身份（通知 id 的前缀；空 = 未配对 / 单测）。
  required String hostId,

  /// 前台且**这一台可见**时，正看着的那个会话不提醒。
  required bool appForeground,
  required bool visible,
  required String? currentSid,

  required List<SessionSummary> sessions,

  /// 某个会话本地的条目（只含**已订阅**的会话：没访问过的会话这里没有内容）。
  required Iterable<ChatItem> Function(String sid) itemsOf,

  /// 某个会话的任务行。
  required List<JobRow> Function(String sid) jobsOf,

  /// 某个会话是不是"你没看着时跑完了一轮、还没点开"。
  required bool Function(String sid) completionUnreadOf,

  /// 现在（毫秒）—— 由调用方给，方便用例钉窗口边界。
  required int nowMs,

  Duration jobWindow = kJobNoticeWindow,
}) {
  final notices = <AttentionNotice>[];
  for (final session in sessions) {
    // 前台、**这一台可见**、且正看着它 ⇒ 不提醒：结果就在眼前（与"完成绿点"同一条判据）。
    // "可见"这一条是池化之后才需要的：别的电脑的"当前会话"用户根本没在看着。
    if (appForeground && visible && session.sid == currentSid) continue;
    final title = session.displayTitle;
    for (final item in itemsOf(session.sid)) {
      if (item is ApprovalItem && !item.decided) {
        notices.add(
          AttentionNotice(
            id: noticeIdFor(hostId: hostId, kind: 'approval', id: item.itemId),
            kind: NoticeKind.approval,
            sid: session.sid,
            title: '等你审批 · $title',
            body: item.title.isEmpty ? '有一项操作需要你确认' : item.title,
            itemId: item.itemId,
            allowLabel: '允许一次',
            denyLabel: '拒绝',
          ),
        );
      }
      // 提问：`ask_user_question` 的 `tool/call` 还没有 `tool/result` ——
      // 与连接器认身份的那条规则同一个判据（`connector/src/dsh/question-call.ts`）。
      if (item is ToolCallItem &&
          item.name == 'ask_user_question' &&
          item.status == ToolCallStatus.running) {
        notices.add(
          AttentionNotice(
            id: noticeIdFor(hostId: hostId, kind: 'question', id: item.itemId),
            kind: NoticeKind.question,
            sid: session.sid,
            title: '有人在问你 · $title',
            body: '点开回答（通知上不答题：答案要按问题逐条给）',
          ),
        );
      }
    }
    // 后台任务结束：**一个任务一条**（同一会话同时结束三个任务就是三件事），
    // 按 `jobId` 去重 —— 通知 id 从 jobId 算，重复帧不会变成两条。
    // 摘要优先取 `detail` 的前两行（电脑侧给失败原因/输出尾巴），其次是进度，
    // 都没有就说明"结束了但没话说"，不给假摘要。
    //
    // Note: 为什么任务单独一类、为什么是 30 分钟窗口 —— 见
    // `.agents/notes/implemented/2026-11-09-job-completion-notice.md`
    for (final job in jobsOf(session.sid)) {
      final finishedAt = job.finishedAt;
      if (finishedAt == null || job.isLive) continue;
      if (nowMs - finishedAt > jobWindow.inMilliseconds) continue;
      final detail = (job.detail ?? '').trim();
      final progress = (job.progress ?? '').trim();
      final summary = detail.isNotEmpty
          ? detail.split('\n').take(2).join(' ').trim()
          : (progress.isNotEmpty ? progress : '任务已结束，点开查看详情');
      notices.add(
        AttentionNotice(
          id: noticeIdFor(hostId: hostId, kind: 'job', id: job.id),
          kind: NoticeKind.completed,
          sid: session.sid,
          title: '后台任务${job.statusText} · ${job.label}',
          body: summary,
        ),
      );
    }
    if (completionUnreadOf(session.sid)) {
      notices.add(
        AttentionNotice(
          id: noticeIdFor(hostId: hostId, kind: 'completed', id: session.sid),
          kind: NoticeKind.completed,
          sid: session.sid,
          title: '跑完了 · $title',
          body: '你没看着它的时候这一轮结束了',
        ),
      );
    }
  }
  return notices;
}

/// 已经贴上去的那一批（`id → notice`），以及"该贴的"与"已贴的"怎么对齐。
///
/// 它只记"我贴过什么"这一件事 —— 判据（[desiredNotices]）与端口都在外面。
/// 于是"撤一条已经贴过的"只有一处实现，而不是在应答路径上再手写一遍。
class NoticeBoard {
  final Map<int, AttentionNotice> _active = <int, AttentionNotice>{};

  /// 已贴的 id（收口时要逐个撤掉）。
  Iterable<int> get ids => _active.keys;

  bool get isEmpty => _active.isEmpty;

  /// 把"该贴的"与"已贴的"对齐：**消失的撤、新增的贴、同样的不动**。
  /// 返回要做的两批动作（本类不碰端口）。
  ({List<AttentionNotice> show, List<int> cancel}) reconcile(
    List<AttentionNotice> desired,
  ) {
    final wanted = <int, AttentionNotice>{
      for (final notice in desired) notice.id: notice,
    };
    final cancel = <int>[];
    for (final id in _active.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      _active.remove(id);
      cancel.add(id);
    }
    final show = <AttentionNotice>[];
    for (final entry in wanted.entries) {
      if (_active.containsKey(entry.key)) continue;
      _active[entry.key] = entry.value;
      show.add(entry.value);
    }
    return (show: show, cancel: cancel);
  }

  /// 撤掉一条（应答完 / 已失效）：返回它的 id，`null` = 本来就没贴。
  int? drop(int id) => _active.remove(id) == null ? null : id;

  /// 全撤（收口）：返回所有已贴的 id。
  List<int> clear() {
    final ids = _active.keys.toList();
    _active.clear();
    return ids;
  }
}
