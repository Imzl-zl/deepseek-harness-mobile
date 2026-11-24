/// **设备级偏好（`device.*`）的唯一持有者与写入口**。
///
/// ## 这一簇为什么单独一个类
///
/// 七项偏好是同一个形状：**typed 值 + wire 字符串 + 落盘键 + 一条"改了才写"的
/// 守卫**。它们原先住在 `AppModel` 里：七个字段、七个 getter、七个几乎逐字相同的
/// setter（守卫 → 改内存 → `notifyListeners` → 落盘），外加两条读回路径
/// （`_applyDevicePreferences` / `_restorePreferences`）。同一件事写了四遍，
/// 加一档偏好就要再抄一遍 —— 2026-11-24 加「会话排序」时正是这样多出 20 行、
/// 把尺寸棘轮（`verify-size.mjs`，只降不升）顶破了。
///
/// 现在真值只有一份：值在这里，写只走 [_persist]（装配了 `UiStateStore` 就写它的
/// `device.*` 键；没装配那条缝时（单测 / 老装配路径）退回 `PreferenceStore` 的
/// 同名 meta 键）。`AppModel` 只剩**读的 passthrough**（getter，不占它的方法预算）
/// 与一个 `devicePrefs` 入口；加一档偏好 = 这里一个字段 + 一个 getter +
/// 一个 setter，不去碰 façade。
///
/// 取舍见 `.agents/notes/implemented/2026-11-10-size-budget-ratchet.md`；
/// 两档「会话排序」本身见 `.agents/notes/implemented/2026-11-24-session-order-by-recency.md`。
library;

import '../core/type_scale.dart';
import '../model/preferences.dart';
import '../model/route_policy.dart';
import '../model/session_order.dart';
import '../model/task_notice_policy.dart';
import 'store.dart';
import 'ui_state.dart';

class DevicePrefs {
  DevicePrefs({
    required PreferenceStore? prefs,
    required UiStateStore? Function() uiState,
    required bool Function() isDisposed,
    required void Function() onChanged,
  }) : _prefs = prefs,
       _uiState = uiState,
       _isDisposed = isDisposed,
       _onChanged = onChanged;

  /// **没装配 `UiStateStore` 时的退路键**（meta 表）：
  /// 契约两端共用的字符串，改动等于作废用户的偏好。
  static const String kTranscriptViewKey = 'transcript_view';
  static const String kPerformanceUsageKey = 'performance_usage';
  static const String kCollapseTimingKey = 'collapse_timing';
  static const String kRoutePolicyKey = 'route_policy';
  static const String kSessionOrderKey = 'session_order';
  static const String kTaskNoticeKey = 'notify_tasks';
  static const String kUiScaleKey = 'ui_scale_index';

  final PreferenceStore? _prefs;

  /// 当前装配的 `UiStateStore`。**闭包**而不是值：它在首帧前（`loadUiState()`）
  /// 才装上，而这个对象在 `AppModel` 构造时就建好了。
  final UiStateStore? Function() _uiState;

  /// `AppModel` 被 `dispose` 之后不再改任何值（与原七个 setter 的守卫同一语义）。
  final bool Function() _isDisposed;

  /// 值变了之后通知界面（`AppModel.notifyListeners`）。
  final void Function() _onChanged;

  TranscriptView _transcriptView = TranscriptView.standard;
  PerformanceUsage _performanceUsage = PerformanceUsage.detailed;
  CollapseTiming _collapseTiming = CollapseTiming.completion;

  /// 这台手机想走哪条路（`model/route_policy.dart`）：**配对与连接共用**。
  RoutePolicy _routePolicy = RoutePolicy.auto;

  /// 会话列表的组内排序档（`model/session_order.dart`）：默认「最近更新」。
  ///
  /// 与桌面的默认档同一条（`orderBy: 'updated'`，
  /// `packages/client/ui-workspace/src/client/stores.ts:86`）：桌面按 `updatedAt`
  /// 排，手机以前按账本行序 —— 于是"刚发过消息的那个"排在老会话后面
  /// （2026-11-24 用户反馈「新建会话怎么显示的不是第一个」）。
  SessionOrder _sessionOrder = SessionOrder.updated;

  /// 后台任务结束要不要提醒（默认关；判据见 `model/task_notice_policy.dart`）。
  TaskNoticePolicy _taskNoticePolicy = TaskNoticePolicy.off;

  int _uiScaleIndex = kUiScaleDefaultIndex;

  // -------------------------------------------------------------------------
  // 读
  // -------------------------------------------------------------------------

  TranscriptView get transcriptView => _transcriptView;
  PerformanceUsage get performanceUsage => _performanceUsage;

  /// 轮组的过程什么时候收起来（`docs/subsystems/turn-groups.md`）。
  CollapseTiming get collapseTiming => _collapseTiming;

  RoutePolicy get routePolicy => _routePolicy;
  SessionOrder get sessionOrder => _sessionOrder;
  TaskNoticePolicy get taskNoticePolicy => _taskNoticePolicy;

  /// 界面字号档位的下标（[kUiScaleSteps] / `kUiScaleLabels` 的下标）。
  int get uiScaleIndex => _uiScaleIndex;

  /// 当前倍率（叠在系统字号之上；`main.dart` 把它乘进 `MediaQuery.textScaler`）。
  double get uiScale => kUiScaleSteps[_uiScaleIndex];

  // -------------------------------------------------------------------------
  // 读回（两条装配路径，各有各的来源；认不出就保持默认 —— 不猜）
  // -------------------------------------------------------------------------

  /// 从 `UiStateStore` 读回（`AppModel.loadUiState` 在**首帧前**调一次）。
  void applyFromStore(UiStateStore store) {
    final transcript = TranscriptView.fromWire(store.transcriptView);
    if (transcript != null) _transcriptView = transcript;
    final performance = PerformanceUsage.fromWire(store.performanceView);
    if (performance != null) _performanceUsage = performance;
    final collapse = CollapseTiming.fromWire(store.collapseTiming);
    if (collapse != null) _collapseTiming = collapse;
    final route = RoutePolicy.fromWire(store.routePolicy);
    if (route != null) _routePolicy = route;
    final taskNotice = TaskNoticePolicy.fromWire(store.taskNotice);
    if (taskNotice != null) _taskNoticePolicy = taskNotice;
    final order = SessionOrder.fromWire(store.sessionOrder);
    if (order != null) _sessionOrder = order;
    final scale = store.uiScaleIndex;
    if (scale != null) _uiScaleIndex = scale.clamp(0, kUiScaleSteps.length - 1);
  }

  /// 从 `PreferenceStore` 的 meta 键读回：**只在没装配 `UiStateStore` 时**用
  /// （`AppModel.start()` 里那条退路，单测都走它）。
  Future<void> loadFromPrefs() async {
    final transcript = TranscriptView.fromWire(
      await _prefs?.read(kTranscriptViewKey),
    );
    if (transcript != null) _transcriptView = transcript;
    final performance = PerformanceUsage.fromWire(
      await _prefs?.read(kPerformanceUsageKey),
    );
    if (performance != null) _performanceUsage = performance;
    final collapse = CollapseTiming.fromWire(
      await _prefs?.read(kCollapseTimingKey),
    );
    if (collapse != null) _collapseTiming = collapse;
    // 设备级策略：与 `device.*` 同一份值。
    // （旧键 `pairing_prefer` 的迁移在 `UiStateStore.open` 里做，这里不重复。）
    final policy = RoutePolicy.fromWire(await _prefs?.read(kRoutePolicyKey));
    if (policy != null) _routePolicy = policy;
    final sessionOrder = SessionOrder.fromWire(
      await _prefs?.read(kSessionOrderKey),
    );
    if (sessionOrder != null) _sessionOrder = sessionOrder;
    final taskNotice = TaskNoticePolicy.fromWire(
      await _prefs?.read(kTaskNoticeKey),
    );
    if (taskNotice != null) _taskNoticePolicy = taskNotice;
    // 界面字号档位：存的是下标；认不出（没存过 / 坏了）就保持默认档（1.0）。
    final scaleIndex = int.tryParse(await _prefs?.read(kUiScaleKey) ?? '');
    if (scaleIndex != null) {
      _uiScaleIndex = scaleIndex.clamp(0, kUiScaleSteps.length - 1);
    }
  }

  // -------------------------------------------------------------------------
  // 写（每个都是"守卫 → 改内存 → 通知 → 落盘"：落盘只走 [_persist]）
  // -------------------------------------------------------------------------

  /// 切工作步骤展示密度。落盘；同一个值重复切是空操作。
  Future<void> setTranscriptView(TranscriptView view) async {
    if (_isDisposed() || view == _transcriptView) return;
    _transcriptView = view;
    _onChanged();
    await _persist(
      view.wire,
      kTranscriptViewKey,
      (store) => store.setTranscriptView(view.wire),
    );
  }

  /// 切性能与用量的详细程度。落盘；同一个值重复切是空操作。
  Future<void> setPerformanceUsage(PerformanceUsage usage) async {
    if (_isDisposed() || usage == _performanceUsage) return;
    _performanceUsage = usage;
    _onChanged();
    await _persist(
      usage.wire,
      kPerformanceUsageKey,
      (store) => store.setPerformanceView(usage.wire),
    );
  }

  /// 切"过程什么时候收起"。落盘；同一个值重复切是空操作。
  ///
  /// 切完**要清掉用户手动的展开/收起**：那是对旧默认态的手工覆盖，
  /// 留着会让"我改了设置但没反应"（`clearTurnOpen()` 由界面调）。
  Future<void> setCollapseTiming(CollapseTiming timing) async {
    if (_isDisposed() || timing == _collapseTiming) return;
    _collapseTiming = timing;
    _onChanged();
    await _persist(
      timing.wire,
      kCollapseTimingKey,
      (store) => store.setCollapseTiming(timing.wire),
    );
  }

  /// 切连接方式策略（`auto` / `direct` / `relay`）。
  Future<void> setRoutePolicy(RoutePolicy policy) async {
    if (_isDisposed() || policy == _routePolicy) return;
    _routePolicy = policy;
    _onChanged();
    await _persist(
      policy.wire,
      kRoutePolicyKey,
      (store) => store.setRoutePolicy(policy.wire),
    );
  }

  /// 切会话列表的组内排序档。
  ///
  /// **用户一动顺序就会被切到 `manual`**（唯一那一处在 `AppModel.moveSession`）：
  /// `updated` 档下账本序不再是显示序，写完账本不换档等于"拖完看不见变化"。
  Future<void> setSessionOrder(SessionOrder order) async {
    if (_isDisposed() || order == _sessionOrder) return;
    _sessionOrder = order;
    _onChanged();
    await _persist(
      order.wire,
      kSessionOrderKey,
      (store) => store.setSessionOrder(order.wire),
    );
  }

  /// 切后台任务提醒档。
  ///
  /// **值变了之后的副作用不在这个类**：`AppModel.setTaskNoticePolicy` 会让
  /// "该贴的提醒"与"已贴的"对齐（`_syncNotices`，它读的是会话 / 任务状态，不是
  /// 一条偏好），所以那边先 await 这一句、再对账。对账是幂等的，顺序换到落盘之后
  /// 只是"晚一拍"，界面上没有差别。
  Future<void> setTaskNotice(TaskNoticePolicy policy) async {
    if (_isDisposed() || policy == _taskNoticePolicy) return;
    _taskNoticePolicy = policy;
    _onChanged();
    await _persist(
      policy.wire,
      kTaskNoticeKey,
      (store) => store.setTaskNotice(policy.wire),
    );
  }

  /// 切界面字号档位。落盘；同一个档位重复设是空操作；越界**夹到边界**。
  Future<void> setUiScaleIndex(int index) async {
    final clamped = index.clamp(0, kUiScaleSteps.length - 1);
    if (_isDisposed() || clamped == _uiScaleIndex) return;
    _uiScaleIndex = clamped;
    _onChanged();
    await _persist(
      '$clamped',
      kUiScaleKey,
      (store) => store.setUiScaleIndex(clamped),
    );
  }

  /// 落盘：**只有这一处**决定"写到哪个键"。
  Future<void> _persist(
    String wire,
    String fallbackKey,
    Future<void> Function(UiStateStore store) toStore,
  ) async {
    final store = _uiState();
    if (store != null) {
      await toStore(store);
    } else {
      await _prefs?.write(fallbackKey, wire);
    }
  }
}
