/// 把 Flutter 的前后台态翻译成"前台 / 后台"两个值，交给装配层扇出。
///
/// ## 为什么需要它（此前的缺口）
///
/// [SyncClient.setAppState] 是"要不要维持连接"的唯一入口，而在它挂上/// [WidgetsBindingObserver] 之前，`app/lib` 里**没有任何调用点** ——
/// 客户端从构造起就以为自己在**前台**。两个后果，都只在真机上看得见：
///
/// 1. 电脑侧 `foreground` 档的审批接管判据是"前台且已订阅该 sid"
///    （`connector/src/protocol/takeover.ts` 的 `rank`；`presence.ts` 的
///    `foreground` 由 `sync.hello` 的 `app` 字段置位）。于是一部退到后台的
///    手机仍被当成"用户正看着手机"，审批继续推给它、看护在那儿白等；
/// 2. 契约 §2.2 要求"切后台主动断开并停表"、§13 要求三端都不做后台长连接，
///    而连接会一直在后台活着、心跳照走（§9：心跳仅在前台发）。
///
/// 契约 §6.3.1 明写"要恢复桌面接管，把开关设为 `never` 或让 App 退到后台
/// （`foreground` 档下会自动 delegate）"—— 那条产品行为此前是断的。
///
/// ## 为什么住在 `platform/`
///
/// 它读的是 Flutter 绑定的前后台态（平台知识），产出的是**一个布尔值**。
/// `core/` 禁止 import `package:flutter/*`（`app-platform-boundaries.md` §3 的
/// C1/C2 边界，由 `app/tools/verify-platform-boundary.mjs` 的
/// `core-no-platform-import` 机械判定），所以"Flutter 态 → 前台/后台"的翻译
/// 只能发生在 `core/` 之外。它与本目录其他文件是同一种东西：**平台耦合的适配器**。
///
/// ## 为什么只翻一个值、不直接调 `setAppState`
///
/// 一台手机可以同时连几台电脑（`docs/subsystems/app-channel-client.md` §6.4），
/// 每台各有一条连接，而且"退到后台要不要报 foreground"各判各的
/// （`AppModel.connectionForeground`：保活生效时后台也照报）。观察者**只能有一个**
/// —— 挂两个会让"谁先看到"变成一个没人盯的顺序问题 —— 所以它只把那个态翻出来，
/// 扇出交给认识池子的装配层（`main.dart`）。
library;

import 'package:flutter/widgets.dart';

// Note: 只把 resumed 当前台、其余 fail-closed 报后台，以及"客户端现取不持有"的
// 取舍 —— 见 .agents/notes/implemented/2026-10-13-app-lifecycle-observer.md
/// 前后台态的上报者：**唯一的** `WidgetsBindingObserver`。
///
/// 用 `with` 而不是 `implements`：`WidgetsBindingObserver` 是 `mixin class`，
/// 其余十几个回调要的是它的**默认空实现**（`implements` 会要求全部自己实现一遍，
/// 而那正是"每个文件抄 16 个空方法"的来源）。
class AppStateReporter with WidgetsBindingObserver {
  AppStateReporter(this.onChanged);

  /// 态变化（**只有 `resumed` 算前台**，判据见 [isForeground]）。
  ///
  /// 装配层拿它做三件事，都在**同一个扇出处**：每台的通知/保活
  /// （`AppModel.setAppForeground`）、每台连接层的 `setAppState`
  /// （`AppModel.reportToClient`）、退到后台时把在途草稿写下去。
  /// 观察者只有一个，所以"谁先看到"这个问题不存在。
  final void Function(bool foreground) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      onChanged(isForeground(state));
}

/// 这个生命周期态算不算"用户正看着手机"。
///
/// **只有 `resumed` 算前台，其余一律后台**。依据是一手的：Flutter 引擎对
/// `resumed` 的定义是"可见**且有输入焦点**"，对 `inactive` 的定义是
/// "至少一个视图可见、但都没有输入焦点"（来电、权限弹窗、分屏失焦、
/// 通知栏下拉、任务切换器可见），并明说此态下"应假设随时可能 hidden / paused"
/// （`flutter/engine/src/flutter/lib/ui/platform_dispatcher.dart` 的
/// `AppLifecycleState` 文档注释，本地副本 `D:\soft\flutter\...`）。
///
/// 契约 §6.3.1 的 claim 判据是"用户正看着手机"—— 没有输入焦点就不成立，
/// 所以 fail-closed 报后台。这与社区主流写法一致（只把 `resumed` 当前台），
/// 也与 `interaction-claims.ts` 那条"呈示不了就抛、不替用户决定"同向。
///
/// 代价（如实记录）：分屏失焦、通知栏下拉这类"可见但没焦点"的态也会断开并
/// 还桌面。契约 §2.2 明说"重连是常态，不是异常路径"，回前台立刻重连，
/// 所以代价是一次秒级重连，而不是功能缺失。
bool isForeground(AppLifecycleState state) =>
    state == AppLifecycleState.resumed;
