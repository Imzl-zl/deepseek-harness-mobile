/// 右抽屉「子智能体」面板：**目录树**（直接子级 + 按需展开）。
///
/// 判据与数据流逐条照 DSH Web 的 `CatalogRows`
/// （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:190-408`）：
///
/// | 行为 | Web | 这里 |
/// |---|---|---|
/// | 目录只含直接子级 | `catalog.ts:111-131` | `SubagentCatalog.entries` |
/// | 展开才读子级 | `toggleBranch` → `refreshProjection(child)`（`:570-577`） | `onLoad(childSid)` |
/// | 加载态 | `state==='loading' && entries 空`（`:212`） | 同 |
/// | 错误态 + 重试 | `:222-234` | 同 |
/// | 已知空叶 | `state==='ready' && entries 空`（`:196-198`） | `SubagentCatalog.isKnownLeaf` |
/// | 当前行加粗 | `.currentLabel`（`module.css:237-239`） | `currentSid` |
/// | 收起连带收整枝 | `closeBranch`（`:556-568`） | 同 |
///
/// ## 排布是**按触屏重做**的，不是把桌面的那一行缩小
///
/// 桌面那一行是「活动点 + 左侧 14px disclosure + label + 第二行 + 右侧两行指标」，
/// 前提是鼠标能点 14px、窗口有 336~600px 宽、10px 字号看得清。
/// 手机上这三条都不成立（300dp 面板、手指、DPI 高），于是四处有意偏离：
///
/// 1. **展开按钮在行尾、可点区 44×44**（Web 在左侧、14×17）。鼠标精确点小箭头，
///    手指不行；而且左侧小箭头紧贴"进入"的整行点击区，两种误触都会发生。
/// 2. **不预留 disclosure 槽**（Web 的 `reserveDisclosure`，`:213-216`）。那条
///    规矩是为了让**左缘**的 label 对齐；这里左缘由活动点占住已经对齐，
///    再为 300dp 的行预留 44dp 是纯浪费。
/// 3. **右侧只放 token 一个数**，时长并进详情行（Web 是右侧两行小字）。
/// 4. **行字号 12.5 / 11**，缩进 **12**、树线只画竖线（Web 12 / 10、缩进 16 带短横线）：
///    300dp 里每层 16 到第三层就吃掉 48dp。
///
/// 容器仍是**右抽屉**，不改成 Web 的浮层下拉（设计 §7.8 已定）。
///
/// 数据每帧现算（`catalogOf` / `nodeOf` 都是函数），本组件**只持有**
/// 展开集合与"正在跑 ⇒ 每秒刷新一次时长"。其余全部来自 `AppModel`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/job.dart' show SubagentRow;
import '../model/subagent.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_state_dot.dart';

/// 目录树。
class SubagentTree extends StatefulWidget {
  const SubagentTree({
    super.key,
    required this.rootSid,
    required this.catalogOf,
    required this.nodeOf,
    required this.onOpen,
    required this.onLoad,
    this.currentSid,
    this.emptyText = '没有子智能体。',
    this.clock = _wallClock,
  });

  /// 这一棵树从哪个会话的直接子级开始。
  ///
  /// 空串 = 还没有选中会话 —— 不读、也不说"正在加载"（那会永远转下去）。
  final String rootSid;

  /// sid → 目录（三态 + 直接子级）。
  final SubagentCatalog Function(String sid) catalogOf;

  /// 目录行 → 运行态视图（子会话自己的 running / 计时 / token / 标题）。
  final SubagentNode Function(SubagentRow row) nodeOf;

  /// 点一行 = 进入那个子会话（Web 的 `openChild`，`:279-287`）。
  ///
  /// 第二个参数是**画出这一行的那一层**（`_Level.sid`）—— 父级与 mode 都随行交出，
  /// 与 DSH 在那一层构造地址同一条：`openChild({parentSessionId, childSessionId, mode})`
  /// （`SubagentHeaderLineage.tsx:279-287`）。调用方**不需要**回目录里再查。
  /// Note: 为什么父级不从目录扫描来 —— 见
  /// .agents/notes/implemented/2026-10-23-subagent-parent-and-mode-from-the-layer.md
  final void Function(SubagentNode node, String parentSid) onOpen;

  /// 展开一个子级时**懒加载**它的目录（Web 的 `refreshProjection(child)`）。
  final void Function(String sid) onLoad;

  /// 当前所在会话：它那一行加粗（Web 的 `currentLabel`）。`null` = 没有。
  final String? currentSid;

  /// 读到空时的说法（只有**根级**会显示它；子级空就是什么都不画）。
  final String emptyText;

  /// 现在几点（毫秒）。**注入的缝**：时长"每秒走一格"要能单测，
  /// 而 `DateTime.now()` 在 `flutter test` 的假时钟里不动。
  final int Function() clock;

  @override
  State<SubagentTree> createState() => _SubagentTreeState();
}

/// 墙钟：生产路径用的就是它。
int _wallClock() => DateTime.now().millisecondsSinceEpoch;

class _SubagentTreeState extends State<SubagentTree> {
  /// 展开着的子级（Web 的 `expanded`）。**默认全收起**（`:482-483`）。
  final Set<String> _expanded = <String>{};

  /// 时长是"每秒长一格"的（Web 每层一个 1 秒定时器，`:205-211`），
  /// 所以这一层持有一个 `now`。只在**看得见的行里有在跑的**时才转。
  late int _now = widget.clock();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(SubagentTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父层每次 `AppModel` 通知都会重建这里 —— 趁机对齐"要不要走秒"。
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 看得见的行里有在跑的就走秒，没有就停（**不留一个空转的定时器**）。
  void _syncTicker() {
    final running = _visibleNodes().any((node) => node.running);
    if (running && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _now = widget.clock());
      });
    } else if (!running && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// 当前**看得见**的行：根层 + 每个展开层的子级。
  ///
  /// 递归**带祖先集合**：健康宿主的 catalog 是树（子级不会是自己或自己的祖先），
  /// 而这里喂进来的形状来自线上投影。真出现环时该"到此为止"，不是把栈打穿
  /// —— `StackOverflowError` 在 Flutter 里捕获不了，整页直接白屏。
  List<SubagentNode> _visibleNodes() {
    final out = <SubagentNode>[];
    void visit(String sid, Set<String> ancestors) {
      for (final row in widget.catalogOf(sid).entries) {
        out.add(widget.nodeOf(row));
        if (_expanded.contains(row.id) && !ancestors.contains(row.id)) {
          visit(row.id, {...ancestors, row.id});
        }
      }
    }

    if (widget.rootSid.isNotEmpty) visit(widget.rootSid, {widget.rootSid});
    return out;
  }

  bool _canExpand(SubagentRow row) {
    if (row.isExternal) return false;
    // 只有"它自己的目录**成功读到且为空**"才算已知空叶（`:196-198`）。
    return !widget.catalogOf(row.id).isKnownLeaf;
  }

  void _toggle(SubagentRow row) {
    setState(() {
      if (_expanded.contains(row.id)) {
        // 收起时**连带收起整枝**（Web 的 `closeBranch`，`:556-568`）：
        // 留着深层展开，下次展开会突然多出一大片，读起来像跳帧。
        final closing = <String>{};
        void visit(String sid) {
          if (!_expanded.contains(sid) || closing.contains(sid)) return;
          closing.add(sid);
          for (final child in widget.catalogOf(sid).entries) {
            visit(child.id);
          }
        }

        visit(row.id);
        _expanded.removeAll(closing);
      } else {
        _expanded.add(row.id);
        // **展开才读**（`:570-577`）：catalog 只含直接子级，孙级要现拉。
        widget.onLoad(row.id);
      }
    });
    _syncTicker();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rootSid.isEmpty) return _EmptyNote(widget.emptyText);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 12),
      child: _Level(
        sid: widget.rootSid,
        isRoot: true,
        tree: this,
        ancestors: {widget.rootSid},
      ),
    );
  }
}

/// 一层目录。递归渲染 —— 与 Web 的 `CatalogRows` 同一个形状。
class _Level extends StatelessWidget {
  const _Level({
    required this.sid,
    required this.isRoot,
    required this.tree,
    required this.ancestors,
  });

  final String sid;
  final bool isRoot;
  final _SubagentTreeState tree;

  /// 从根到这一层的 sid（含这一层）。
  ///
  /// 用来**截断环**：某行的 id 已经在自己祖先链上时，不再给它展开能力
  /// 也不再往下画（健康宿主的 catalog 是树，这里防的是线上畸形投影 ——
  /// 递归打穿栈是不可捕获的 `StackOverflowError`，整页白屏）。
  final Set<String> ancestors;

  @override
  Widget build(BuildContext context) {
    final catalog = tree.widget.catalogOf(sid);
    final rows = catalog.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (catalog.isLoadingEmpty) const _Notice('正在加载子智能体…'),
        if (catalog.state == SubagentCatalogState.error)
          _ErrorRow(onRetry: () => tree.widget.onLoad(sid)),
        if (rows.isEmpty &&
            isRoot &&
            catalog.state == SubagentCatalogState.ready)
          _EmptyNote(tree.widget.emptyText),
        for (final row in rows) _node(context, row),
      ],
    );
  }

  Widget _node(BuildContext context, SubagentRow row) {
    final node = tree.widget.nodeOf(row);
    // 环上的一行：不再给展开能力（见 [ancestors]）。
    final expandable = tree._canExpand(row) && !ancestors.contains(row.id);
    final expanded = expandable && tree._expanded.contains(row.id);
    final childCatalog = tree.widget.catalogOf(row.id);
    // 展开着但子级还在读：`aria-busy` 那一档（`:376-402`）。
    final childLoading = childCatalog.isLoadingEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SubagentRow(
          node: node,
          now: tree._now,
          expanded: expanded,
          current: tree.widget.currentSid == row.id,
          onTap: row.isExternal ? null : () => tree.widget.onOpen(node, sid),
          onToggle: expandable ? () => tree._toggle(row) : null,
        ),
        if (expanded)
          Padding(
            // 缩进 **12**，不是 Web 的 16：300dp 的面板里每层 16 会在第三层
            // 吃掉 48dp（16%），而右抽屉本来就窄（设计 §7.8）。
            padding: const EdgeInsets.only(left: 12),
            child: Container(
              // 树线：Web 的 `.children` 是 `margin-left:16; padding-left:3`
              // 加一条 `0.5px border-l2`（`module.css:288-300`）。
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: context.dshColors.borderL2,
                    width: 0.5,
                  ),
                ),
              ),
              padding: const EdgeInsets.only(left: 4),
              child: childLoading
                  ? const _Notice('正在加载子智能体…')
                  : _Level(
                      sid: row.id,
                      isRoot: false,
                      tree: tree,
                      ancestors: {...ancestors, row.id},
                    ),
            ),
          ),
      ],
    );
  }
}

/// 一行。
///
/// ## 触屏排布（与 Web 的那一行不同，逐条有意偏离）
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │ ●  调研实现                    12.3K tok ⌄│
/// │    可继续 · 已完成 · 1分05秒               │
/// └──────────────────────────────────────────┘
/// ```
///
/// 1. **展开按钮搬到行尾、可点区 44×44**。Web 把 disclosure 放在 label **左边**
///    （`module.css:186-216`，14×17），靠鼠标精确点击 + 键盘方向键；手机上
///    那就是在 44 高的行里塞一个 14px 的小靶子，紧挨着"进入"的整行点击区 ——
///    想进会话却展开了、想展开却进了会话，两种误触都会发生。
///    行尾 44×44 是可拇指够到的一侧（右抽屉贴着右缘），且与整行点击区分开。
/// 2. **不再预留 disclosure 槽**。Web 的 `reserveDisclosure`（`:213-216`）是为了
///    让**左缘**的 label 对齐；这里左缘由活动点（始终存在）占住，已经对齐，
///    再为 300dp 的行宽预留 44dp 是纯浪费。
/// 3. **右列只放 token 一个数**，时长并进详情行 —— 见 `model/subagent.dart` 文件头。
/// 4. **不留"进入"箭头**：整行都是进入区，行尾已经是展开按钮，再塞一枚
///    `chevronRight` 会让同一侧出现两个箭头、两个含义。
class _SubagentRow extends StatelessWidget {
  const _SubagentRow({
    required this.node,
    required this.now,
    required this.expanded,
    required this.current,
    required this.onTap,
    required this.onToggle,
  });

  final SubagentNode node;
  final int now;
  final bool expanded;

  /// 是不是当前会话那一行（加粗）。
  final bool current;

  final VoidCallback? onTap;
  final VoidCallback? onToggle;

  /// 展开按钮的可点区（Material 的最小触控目标）。
  static const double toggleSize = 44;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final tokenText = node.tokenText;
    return InkWell(
      onTap: onTap,
      child: Container(
        // 行高照 Web 的 44（`module.css:139-157`），但**左右内边距按触屏重排**：
        // 左 9 留给活动点、右 0 让展开按钮贴到行尾（它自己带 44 的靶心）。
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.only(left: 9),
        child: Row(
          children: [
            // 活动点：14×17 的槽（`.rowActivitySlot`，`module.css:177-184`）。
            // `StateDot` 的语义与 DSH 同一张表（`:336-338`）：
            // 在跑=转圈、正常完成=绿、其余=灰。
            SizedBox(
              width: 14,
              height: 17,
              child: Center(
                child: DshStateDot(switch (node.activity) {
                  SubagentActivity.running => DshStateDotState.ongoing,
                  SubagentActivity.completed => DshStateDotState.done,
                  SubagentActivity.inactive => DshStateDotState.idle,
                }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      node.row.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // 触屏密度：12.5（Web 是 12）。当前行加粗照 `.currentLabel`。
                        fontSize: 12,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                        color: c.labelPrimary,
                      ),
                    ),
                    Text(
                      node.detailLine(now),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // `.summary` 是 10/15（`module.css:241-246`）；触屏抬到 11。
                      style: TextStyle(fontSize: 11, color: c.labelTertiary),
                    ),
                  ],
                ),
              ),
            ),
            if (tokenText != null) ...[
              const SizedBox(width: 8),
              Text(
                tokenText,
                style: TextStyle(
                  fontSize: 11,
                  color: c.labelTertiary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            if (onToggle != null)
              _expandToggle(c)
            else
              const SizedBox(width: 9),
          ],
        ),
      ),
    );
  }

  /// 展开 / 收起：**行尾 44×44**。
  ///
  /// 无障碍名逐字照 DSH 的 `branch.expand` / `branch.collapse`
  /// （`ui-subagent/src/client/locales.ts:34-35`）——
  /// 一个只有箭头的按钮没有任何可读文本，测试也没有稳定的定位点。
  Widget _expandToggle(DshColorTokens c) {
    final label = node.row.displayLabel;
    return Tooltip(
      message: expanded ? '收起 $label 的下级子智能体' : '展开 $label 的下级子智能体',
      child: InkWell(
        onTap: onToggle,
        child: SizedBox(
          width: toggleSize,
          height: toggleSize,
          child: Center(
            child: AnimatedRotation(
              // 收起时指向右（"还有下一层"），展开时转 90° 指向下。
              // Web 同一枚字形转 90°（`.disclosureOpen`，`module.css:214-216`）。
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 120),
              child: DshIcon('chevronRight', size: 14, color: c.labelTertiary),
            ),
          ),
        ),
      ),
    );
  }
}

/// 提示行（`.notice`：`padding:8px 10px; 11/16; label-tertiary`，`:331-337`）。
class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          height: 16 / 12,
          color: context.dshColors.labelTertiary,
        ),
      ),
    );
  }
}

/// 错误行：一句「无法加载子智能体」+「重试」。
///
/// 文案照 DSH 的 zh 词典（`ui-subagent/src/client/locales.ts:23,25`）。
/// **原始错误不进这一行**：它进 `AppModel.lastError`（空态那里显示），
/// 而这一行要的是用户能做的下一个动作（点重试）。
class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '无法加载子智能体',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
          ),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(DshRadius.sm),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DshIcon('refresh', size: 12, color: c.stateError),
                    const SizedBox(width: 3),
                    Text(
                      '重试',
                      style: TextStyle(fontSize: 12, color: c.stateError),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 空态：居中一句话（**只有读到空才算空**，没读到是上面那句加载中）。
class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 20 / 13,
          color: context.dshColors.labelTertiary,
        ),
      ),
    );
  }
}
