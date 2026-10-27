/// 条目列表的**派生表**：改动清单 / 每轮产出路径 / 每轮收口助手 / 提及表。
///
/// ## 为什么单独成类
///
/// 这四张表是"`List<ChatItem>` 的纯函数"，却各自带一份缓存，散在 `AppModel` 的
/// 4000 行里。它们**只依赖条目列表**（不依赖会话、能力位、客户端），所以是收窄计划
/// （`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md` 第二簇）里最先能搬的一块。
///
/// 搬出来的判据由 [SourceCache] 承担：**列表对象换了才重算**（`SessionStore` 每次归并
/// 都换一个新的 `List.unmodifiable`）。四份缓存各写一遍 `identical` 曾是四个会漏的地方。
///
/// ## 边界
///
/// 它不持有条目：拿到的是"当前条目"的取值函数（[items]）。于是它能在纯 Dart 用例里
/// 直接构造，也不会把"当前会话是谁"这件事复制一份。
library;

import '../model/chat_item.dart';
import '../model/file_mentions.dart';
import 'cache.dart';

class ItemDerivations {
  ItemDerivations(this.items);

  /// 当前会话的条目（`AppModel.items` 的快照语义：没开会话就是空表）。
  final List<ChatItem> Function() items;

  /// `path → 改动统计`（按首次出现的倒序：最近改的在前）。
  List<({String path, ({int added, int removed})? stat})> get changedFiles {
    final source = items();
    return _changedFilesCache.read(source, () => _buildChangedFiles(source));
  }

  final SourceCache<List<({String path, ({int added, int removed})? stat})>>
  _changedFilesCache =
      SourceCache<List<({String path, ({int added, int removed})? stat})>>();

  List<({String path, ({int added, int removed})? stat})> _buildChangedFiles(
    List<ChatItem> source,
  ) {
    final indexOf = <String, int>{};
    final rows = <({String path, ({int added, int removed})? stat})>[];
    // 每个路径**最后一次被改**时扫到第几条 —— 排序用它。
    //
    // 不能直接 `rows.reversed`：那是"按首次出现倒序"，与"刚动过的排第一"是两件事
    // （同一文件被改两次时，它会排到后面去）。这个差是变异校验发现的：
    // 把去重删掉时整份套件没有一条红，补用例时才发现注释与实现不一致。
    final lastTouched = <int>[];
    for (final item in source) {
      if (item is! ToolCallItem) continue;
      final path = item.changedPath;
      if (path == null) continue;
      final existing = indexOf[path];
      if (existing == null) {
        indexOf[path] = rows.length;
        rows.add((path: path, stat: item.diffStat));
        lastTouched.add(item.seq);
      } else {
        // 后来的改动覆盖统计（同一文件在一轮里被改两次时，看的是后一次）。
        rows[existing] = (
          path: path,
          stat: item.diffStat ?? rows[existing].stat,
        );
        lastTouched[existing] = item.seq;
      }
    }
    final order = List<int>.generate(rows.length, (i) => i)
      ..sort((a, b) => lastTouched[b].compareTo(lastTouched[a]));
    return List<({String path, ({int added, int removed})? stat})>.unmodifiable(
      [for (final i in order) rows[i]],
    );
  }

  /// 某一轮**产出过**的路径 —— 正文提及的词表。
  ///
  /// 与 DSH 同一条：词表是**这一轮**的产出，不是工作区文件清单
  /// （`ui-deliverables/src/client/turn-deliverables.ts:132-160`）。
  /// 判据也照它：**只有成功的变更调用算产出**（`:134-137` 的
  /// "failed results contribute nothing"），读取与未知工具不算。
  List<String> producedPathsOf(int? turn) {
    if (turn == null) return const <String>[];
    return _pathsByTurn[turn] ?? const <String>[];
  }

  final SourceCache<Map<int, List<String>>> _pathsByTurnCache =
      SourceCache<Map<int, List<String>>>();

  Map<int, List<String>> get _pathsByTurn {
    final source = items();
    return _pathsByTurnCache.read(source, () => _buildPathsByTurn(source));
  }

  Map<int, List<String>> _buildPathsByTurn(List<ChatItem> source) {
    final byTurn = <int, List<String>>{};
    final seen = <int, Set<String>>{};
    for (final item in source) {
      if (item is! ToolCallItem) continue;
      final turn = item.turn;
      final path = item.changedPath;
      if (turn == null || path == null) continue;
      // 失败的结果不算产出（桌面同一句：failed results contribute nothing）。
      if (item.status != ToolCallStatus.completed) continue;
      final (turns, paths) = (byTurn, seen);
      if (!(paths[turn] ??= <String>{}).add(path)) continue;
      (turns[turn] ??= <String>[]).add(path);
    }
    return <int, List<String>>{
      for (final entry in byTurn.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    };
  }

  /// 某条消息里的**文件提及表**（`token → path`），没有提及就是 `null`。
  ///
  /// 只在**收口那条助手正文**上给：桌面把提及限定在"这一轮收口的那条助手消息"
  /// （`ui-chat/src/client/chat/AssistantNodeView.tsx:19-27`）。
  Map<String, String>? fileMentionsOf(ChatItem item) =>
      _mentionTables[item.itemId];

  final SourceCache<Map<String, Map<String, String>>> _mentionTableCache =
      SourceCache<Map<String, Map<String, String>>>();

  Map<String, Map<String, String>> get _mentionTables =>
      _mentionTableCache.read(items(), _buildMentionTables);

  Map<String, Map<String, String>> _buildMentionTables() {
    final byItem = <String, Map<String, String>>{};
    for (final entry in _closingAssistantByTurn.entries) {
      final item = entry.value;
      if (item.text.isEmpty) continue;
      final spans = resolveFileMentions(
        item.text,
        knownPaths: producedPathsOf(entry.key),
      );
      if (spans.isEmpty) continue;
      byItem[item.itemId] = fileMentionTargets(spans);
    }
    return byItem;
  }

  /// 每一轮**收口的那条助手正文**（`turn → 条目`）。
  ///
  /// 判据照桌面（`ui-chat/src/client/chat/AssistantNodeView.tsx:19-27`）：
  /// 轮次要**已收口**（有轮次过程行 `p:<turn>`），且这条是这一轮**最后一条**
  /// 带正文的助手消息（桌面的 `tail.closing.finalNode`）。
  final SourceCache<Map<int, MessageItem>> _closingAssistantCache =
      SourceCache<Map<int, MessageItem>>();

  Map<int, MessageItem> get _closingAssistantByTurn {
    final source = items();
    return _closingAssistantCache.read(
      source,
      () => _buildClosingAssistant(source),
    );
  }

  Map<int, MessageItem> _buildClosingAssistant(List<ChatItem> source) {
    final closed = <int>{};
    final last = <int, MessageItem>{};
    for (final item in source) {
      if (item is TurnProcessItem) {
        final turn = item.turn;
        if (turn != null) closed.add(turn);
        continue;
      }
      if (item is! MessageItem ||
          item.role != MessageRole.assistant ||
          item.turn == null ||
          item.text.trim().isEmpty) {
        continue;
      }
      last[item.turn!] = item;
    }
    return <int, MessageItem>{
      for (final turn in closed)
        if (last[turn] != null) turn: last[turn]!,
    };
  }
}
