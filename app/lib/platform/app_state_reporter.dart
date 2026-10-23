/// 把 Flutter 的前后台态翻译成协议的 [AppState] 报给连接（契约 §2.2、§5.4、§9）。
///
/// ## 为什么需要它（此前的缺口）
///
/// [SyncClient.setAppState] 是"要不要维持连接"的唯一入口，而在它挂上
/// [WidgetsBindingObserver] 之前，`app/lib` 里**没有任何调用点** ——
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
/// 它读的是 Flutter 绑定的前后台态（平台知识），产出的是 `core/` 的接口调用。
/// `core/` 禁止 import `package:flutter/*`（`app-platform-boundaries.md` §3 的
/// C1/C2 边界，由 `app/tools/verify-platform-boundary.mjs` 的
/// `core-no-platform-import` 机械判定），所以"Flutter 态 → 协议态"的翻译
/// 只能发生在 `core/` 之外。它与本目录其他文件是同一种东西：**平台耦合的适配器**。
///
/// ## 为什么持的是"取值函数"而不是客户端
///
/// 装配点的 `_app` 会被换掉（重新配对、清凭据都重建 `AppModel`），而 observer
/// 在 `initState` 只注册一次。直接持一个客户端，就会在换掉之后继续往**旧的
/// 那个**上报 —— 而旧客户端已经 `close()` 过，上报全是无声的空转。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/sync_client.dart';

// Note: 只把 resumed 当前台、其余 fail-closed 报后台，以及"客户端现取不持有"的
// 取舍 —— 见 .agents/notes/implemented/2026-10-13-app-lifecycle-observer.md
/// 前后台态的上报者：把每次态变化翻译成一次 [SyncClient.setAppState]。
///
/// 用 `with` 而不是 `implements`：`WidgetsBindingObserver` 是 `mixin class`，
/// 其余十几个回调要的是它的**默认空实现**（`implements` 会要求全部自己实现一遍，
/// 而那正是"每个文件抄 16 个空方法"的来源）。
class AppStateReporter with WidgetsBindingObserver {
  AppStateReporter(this._clientOf, {this.onState});

  /// 当前那个客户端。**每次现取**：理由见文件头"为什么持的是取值函数"。
  final SyncClient? Function() _clientOf;

  /// 同一个态变化的第二个消费者（装配点是 `AppModel.setAppForeground`）。
  ///
  /// **为什么共用这一个观察者**：`AppLifecycleState` 只从 `WidgetsBinding` 来，
  /// 挂两个观察者会让"谁先看到"变成一个没人盯的顺序问题；而"只有 `resumed`
  /// 算前台"这条判据也只该有一份（[isForeground]）。
  final void Function(AppLifecycleState state)? onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onState?.call(state);
    final client = _clientOf();
    // 启动过程里还没有客户端：那一次无可上报。**这不是静默兜底** ——
    // 客户端自己的初相就是 `foreground`，而移动端的冷启动必然在前台
    // （引擎要附着到视图上才会走到这里），所以"跳过"与"报 foreground"等价。
    if (client == null) return;
    unawaited(client.setAppState(appStateOf(state)));
  }
}

/// Flutter 的前后台态 → 协议的 [AppState]（契约只有两档）。
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
AppState appStateOf(AppLifecycleState state) =>
    isForeground(state) ? AppState.foreground : AppState.background;

/// 这个生命周期态算不算"用户正看着手机"。
///
/// **判据只有这一处**：协议侧（[appStateOf]）与通知侧
/// （`AppModel.setAppForeground`）都读它 —— 两处各写一遍
/// `state == resumed` 就是同一条规则两个表达。
bool isForeground(AppLifecycleState state) =>
    state == AppLifecycleState.resumed;
