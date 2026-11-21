/// 一个会话的**子智能体目录**缓存：四态 + 迁移规则。
///
/// ## 为什么自成一体（而不是留在 `AppModel` 里）
///
/// 这一格状态原来直接在 `AppModel` 上：四态塌成三态、迁移散在读取路径的四个
/// 分支里。于是**"读到过但这次失败"与"从没读过"在界面上是同一句话** ——
/// 症状是面板永远转圈，而手里没有一处事实能回答"到底有没有人在读"
/// （2026-11-21 真机：子智能体面板从连接操作进去一直转圈）。
///
/// 搬出来之后，这一格只有三条判据，且都在本文件里：
///
/// 1. **迁移只有这五处**（[begin] / [applied] / [keep] / [fail] / [parentOf]），
///    读取路径不许直接拼 `SubagentCatalog`；
/// 2. **失败保留上一次的内容**（[keep]）：清成 `error` 等于把"曾经读到过"
///    改写成"从没读到过"，而电脑侧的摘要还在 —— 下一次带摘要的读取拿到
///    `notModified`，这一屏就再也拿不回正文；
/// 3. **`notModified` 而手里没有内容 = 不变量破了**：调用方必须落成 [fail]
///    （界面上有「重试」），**不能**停在 `loading`（界面上只有转圈）。
///
/// 与 Web 的对应：`SubagentHeaderLineage.tsx:196-198,212-234,465-467` 的
/// `idle / loading / error / ready` 四档。`idle` ⇒ 这里的 `never`。
library;

import '../core/job.dart' show SubagentRow;
import '../model/subagent.dart';

/// sid → 目录结论。**没有第二份状态**：界面上那句"正在加载 / 无法加载 / 没有子智能体"
/// 全部从 [of] 读出来。
class SubagentCatalogCache {
  final Map<String, SubagentCatalog> _bySid = <String, SubagentCatalog>{};

  /// 一个会话的目录（本进程从没读过 = [SubagentCatalog.never]）。
  SubagentCatalog of(String sid) =>
      _bySid[sid] ?? const SubagentCatalog.never();

  /// 手里有没有这一包。`ready` 才算法定意义上的"有" —— `loading` 带着的
  /// entries 是上一次的内容，`error` 没有内容。
  bool holds(String sid) => of(sid).state == SubagentCatalogState.ready;

  /// 记一次"开始读了"：**保留上一次的内容**（刷新不闪空，Web`:244-245`）。
  void begin(String sid) {
    _bySid[sid] = SubagentCatalog.loading(entries: of(sid).entries);
  }

  /// 读到正文。
  void applied(String sid, List<SubagentRow> entries) {
    _bySid[sid] = SubagentCatalog.ready(entries);
  }

  /// 这次没读成，但手里有上一次的内容 ⇒ 内容留着，状态仍是 `ready`
  /// （界面上继续显示那一棵树，原因在 `AppModel.lastError`）。
  void keep(String sid) {
    final held = of(sid);
    if (held.state == SubagentCatalogState.ready) return;
    _bySid[sid] = SubagentCatalog.ready(held.entries);
  }

  /// 这次没读成，而且手里没有内容 ⇒ `error`（界面上是"无法加载 + 重试"那一行）。
  void fail(String sid) {
    _bySid[sid] = const SubagentCatalog.failed();
  }

  /// 在**已读到的目录**里找 [sid] 这一行，返回它所在的父级 sid（找不到 = `null`）。
  ///
  /// **只服务 `chat_page.dart` 的 `_subagentParentSid` 第 2 档**：进入子会话时父级
  /// 由画出那一行的那一层交出（DSH 的 `openChild(address)`，见
  /// `SubagentHeaderLineage.tsx:279-287`），只有"恢复出来的子会话 + 老连接器"
  /// （行里没有 `parentSessionId`）才需要回头扫目录。DSH 同一条：拿不到
  /// `address.parentSessionId` 时才扫所有已加载的 catalog
  /// （`SubagentHeaderLineage.tsx:790-797` 的 `projectionsBySession` 那一圈）。
  ///
  /// **只扫 `ready` 的**：`loading` / `error` 的 `entries` 是上一次的内容，
  /// 拿它认父级会认到旧关系上；扫不到就如实返回 `null`，由调用方退到下一档 ——
  /// 不猜，也不为找父级发起一轮网络请求。
  String? parentOf(String sid) {
    for (final entry in _bySid.entries) {
      // 自引用：畸形投影里"自己是自己的子级"会让 `←` 原地重进自己。
      if (entry.key == sid) continue;
      if (entry.value.state != SubagentCatalogState.ready) continue;
      if (entry.value.entries.any((row) => row.id == sid)) return entry.key;
    }
    return null;
  }
}
