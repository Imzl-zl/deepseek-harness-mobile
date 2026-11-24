/// 会话列表的**组内排序档**（`device.session_order`）：最近更新 / 手动。
///
/// ## 两档各是什么
///
/// | 档 | 组内顺序 |
/// |---|---|
/// | `updated`（**默认**） | `updatedAt` 降序，并列时 sid 升序。逐字照桌面 DSH 的默认档：`orderBy: 'updated'`（`packages/client/ui-workspace/src/client/stores.ts:86`），排序函数是 `orderByRecency`（同目录 `tree.ts:151-165`） |
/// | `manual` | **账本序** —— `workspace.list` 的 `sessionIds` 行序，也就是拖动 / 上移 / 下移写回去的那个顺序 |
///
/// ## 为什么默认是"最近更新"（2026-11-24）
///
/// 用户原话：「我 APP 新建会话怎么桌面上显示的不是第一个是后面？这都优化几次了。」
/// 桌面按 `updatedAt` 排；手机以前按账本行序 —— 刚发过消息的会话在账本里还躺在
/// 当初被建出来时的位置，于是"最新的那个"排在"几小时前那个"后面，甚至掉进
/// 「展开其余 N 个会话」里。
///
/// 取舍见 `.agents/notes/implemented/2026-11-24-session-order-by-recency.md`。
///
/// ## 为什么 `manual` 不是"第二份顺序"
///
/// 拖动 / 上移 / 下移写的就是**账本**（`workspace.insertSessionBefore`），
/// 所以手动档没有新的存储 —— 它就是账本序本身。多存一份顺序等于同一件事两处表达
/// （桌面存了：`stores.ts:114-119` 的 `sessionOrderByAccount`），手机侧不做。
///
/// **用户一动顺序，档位就切到 `manual`**（唯一那一处在 `AppModel.moveSession`）：
/// `updated` 档下账本序不再是显示序，写完账本却不换档，用户看到的就是"拖了个寂寞"。
library;

/// 组内排序的两档（`device.session_order` 的取值）。
enum SessionOrder {
  /// 最近更新的在前（默认；与桌面 DSH 的默认档同一条）。
  updated('最近更新', 'updated'),

  /// 手动 = **账本序**（拖动 / 上移 / 下移写回去的那个顺序）。
  manual('手动', 'manual');

  const SessionOrder(this.label, this.wire);

  /// 设置页那一行与选择 sheet 显示的名字。
  final String label;

  /// 落盘值（`device.session_order`）。
  final String wire;

  /// 认不出回 `null`（调用方按 [updated] 处理，**不猜** —— 与
  /// `RoutePolicy.fromWire` / `TaskNoticePolicy.fromWire` 同一条纪律）。
  static SessionOrder? fromWire(Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }
}
