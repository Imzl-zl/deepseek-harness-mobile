/// 会话行的**运行态事实**：在跑吗 / 有几个子智能体在跑 / 跑完没看着 / 本轮起点 / 轮号。
///
/// ## 为什么单独成类
///
/// 这五样同源（都从"宿主说这个会话在不在跑"派生），却散在 `AppModel` 的几个不同
/// 区段里，各自带一撮注释解释"为什么不是自建状态机"。收窄计划把它们归成一簇
/// （`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md` 第二簇的剩下半边）。
///
/// ## 真值只有两处写入
///
/// `session.list` 那一包（覆盖式）与 `status` 帧（实时）。DSH 的浏览器吃的就是这条推送
/// （`packages/api/session-controller/src/client/index.ts:118-119`），手机不再自己数
/// `turn/start` / `turn/end` —— 那套三件套已经随推送接入整块删掉。
///
/// `turn/start` 只贡献**时间事实**（活时钟起点）与**轮号**（轮组归属），不参与
/// "在不在跑"的判断。
library;

import '../core/sync_client.dart' show SessionStatus;
import '../model/chat_item.dart' show SessionSummary;

class SessionRows {
  SessionRows({required this.rowOf, required this.currentSidOf});

  /// 行事实（`runningChildrenOf` 要读父行的 `subagents`）。
  final SessionSummary? Function(String sid) rowOf;

  /// 当前正在看的会话（决定"收口算不算未读"）。
  ///
  /// 通知不在这里发：`_disposed` 守卫与"值没变不通知"的判据都在装配方
  /// （`AppModel`），这里只保证状态本身对。
  final String? Function() currentSidOf;

  final Set<String> _running = <String>{};
  final Map<String, int> _currentTurn = <String, int>{};
  final Map<String, int> _turnStartedAt = <String, int>{};
  final Set<String> _unread = <String>{};

  /// 这个会话此刻在跑吗（**唯一真值**是 [_running]）。
  bool runningOf(String sid) => _running.contains(sid);

  /// 这一项已经收口但用户没看着（DSH 的 `completionUnread`）。
  bool completionUnreadOf(String sid) => _unread.contains(sid);

  /// 最近一次 `turn/start` 的轮号；`null` = 不知道。
  int? currentTurnOf(String sid) => _currentTurn[sid];

  /// 本轮开始的时刻（毫秒 epoch）；`null` = 不知道（活时钟的起点）。
  int? startedAtOf(String sid) => _turnStartedAt[sid];

  /// 覆盖式同步：`session.list` 那一包。
  void applyList(Iterable<SessionSummary> rows) {
    for (final row in rows) {
      _setRunning(row.sid, row.running);
    }
  }

  /// 宿主推来的一条运行态（`status` 帧）。返回"是否真的变了"。
  bool applyStatus(SessionStatus status) {
    final before = runningOf(status.sid);
    _setRunning(status.sid, status.running);
    return before != status.running;
  }

  /// 用户打开/看着这个会话 ⇒ 未读清零（DSH 的"在主视图里就清"）。
  void markSeen(String sid) {
    _unread.remove(sid);
  }

  /// `turn/start` 的事件事实：起点 + 轮号。
  void noteTurnStart(String sid, {required int time, int? turn}) {
    _turnStartedAt[sid] = time;
    if (turn != null) _currentTurn[sid] = turn;
  }

  /// 这个会话有几个**直接子智能体**此刻在跑。
  ///
  /// 公式照桌面 `ui-workspace/src/client/tree.ts:381-386`：父行
  /// `values.subagentCatalog` 里每个子 id，`running` 为真就计数。桌面写的是
  /// `statuses.get(id)?.running ?? list.byId[id]?.running`；手机上这两条已被
  /// [_running] 合成一份（列表快照走 [applyList]，实时走 [applyStatus]），
  /// 所以只读那一份就等价 —— 不再写"状态优先、列表兜底"的第二套判据。
  int runningChildrenOf(String sid) {
    final children = rowOf(sid)?.subagents;
    if (children == null || children.isEmpty) return 0;
    var count = 0;
    for (final child in children) {
      if (runningOf(child.id)) count += 1;
    }
    return count;
  }

  /// 把"在不在跑"写进去，并在收口时清掉活时钟起点。
  ///
  /// 收口时顺带记一笔"未读的完成"：只有**真的看着它从跑变成不跑**才算，
  /// 所以基线（首包 `session.list`，此时 [_running] 里没有它）不会凭空造出
  /// 一个绿点 —— 与 DSH 的 `previous === undefined` 那条同义
  /// （`packages/ui-session/src/client/index.ts:495`）。
  void _setRunning(String sid, bool running) {
    final was = _running.contains(sid);
    if (running) {
      _running.add(sid);
      _unread.remove(sid);
      return;
    }
    _running.remove(sid);
    _turnStartedAt.remove(sid);
    // 正在看的那个收口不算"未读"：结果就在眼前（DSH 的判据是
    // "停止发生在这个会话之外"，`:65-66` 的字段注释）。
    if (was && sid != currentSidOf()) _unread.add(sid);
  }
}
