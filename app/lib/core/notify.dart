/// 通知与后台保活的**端口**（纯 Dart，零平台依赖）。
///
/// ## 为什么端口在 `core/` 而不是 `platform/`
///
/// `data/app_model.dart` 是"要能在纯 Dart 单测里跑"的那一层
/// （`app-platform-boundaries.md` §3 的 C1/C2 边界，`verify-platform-boundary.mjs`
/// 的 `core-no-platform-import` 机械判定）。前端缝都是这个形状：`SyncClient`
/// 在 `core/`、`PreferenceStore` 在注入侧 —— 通知的**接口**同样只能是一个
/// 不依赖 Flutter 的契约，实现（`platform/notify_android.dart`）才碰通道。
///
/// ## 语义归属
///
/// "**该不该提醒、提醒什么、什么时候撤**"全在 `AppModel`（它持有唯一的状态：
/// 运行态 / 待处理集合 / 当前会话 / 前后台）。这一层不做判断，只声明动作。
///
/// ## 通道协议（安卓实现，`MainActivity.registerNotifications`）
///
/// | 方法 | 方向 | 说明 |
/// |---|---|---|
/// | `status` | Dart→原生 | `{granted, keepAlive}` |
/// | `requestPermission` | Dart→原生 | API 33+ 的 `POST_NOTIFICATIONS` 运行时请求 |
/// | `startKeepAlive` / `stopKeepAlive` | Dart→原生 | 起停前台服务（`remoteMessaging`） |
/// | `show` / `cancel` / `cancelAll` | Dart→原生 | 贴 / 撤通知 |
/// | `openChannelSettings` | Dart→原生 | 跳系统渠道设置（声音/震动归系统） |
/// | `approval` | 原生→Dart | 通知上按下「允许一次 / 拒绝」⇒ `{itemId, outcome}` |
///
/// ## 为什么"没通知权限就不起服务"
///
/// 平台原文：用户拒绝 `POST_NOTIFICATIONS` 时，前台服务的通知**进不了通知抽屉**
/// （只在 Task Manager 里可见）。那条服务唯一可观察的产出就没了 ——
/// 保活却看不见只是白耗电。判据在 `AppModel._syncKeepAlive`。
library;

import 'dart:async';

/// 一条"要你处理"的通知。
class AttentionNotice {
  const AttentionNotice({
    required this.id,
    required this.kind,
    required this.sid,
    required this.title,
    required this.body,
    this.itemId,
    this.allowLabel,
    this.denyLabel,
  });

  /// 通知 id（**由 [noticeIdOf] 从内容算出来**：同一件事永远同一个 id，才撤得掉）。
  final int id;

  final NoticeKind kind;

  /// 属于哪个会话。
  final String sid;

  final String title;

  final String body;

  /// 有它才画**两个按钮**（只有审批有：`i:<approvalId>`）。
  ///
  /// 提问**不给按钮**：`AskUserQuestionAnswer` 是 `{id, selected[], custom?}`，
  /// 一个通知按钮表达不了多选 / 其它 / 逐问作答 —— 硬做就是发明一套与宿主
  /// 不同的答题面（契约 §6.3.1 的"答案批次原样转发"）。
  final String? itemId;

  final String? allowLabel;

  final String? denyLabel;
}

/// 提醒的种类。
enum NoticeKind {
  /// 有人等审批（可带按钮）。
  approval,

  /// 有人在问（只提醒，点开去答）。
  question,

  /// 你不看着的时候那一轮跑完了。
  completed,
}

/// 通知上的按钮按下来之后，原生回给 Dart 的动作。
class NotifyApproval {
  const NotifyApproval({required this.itemId, required this.allowedOnce});

  final String itemId;

  /// `true` = 按的是「允许一次」；`false` = 「拒绝」。
  ///
  /// **没有"总是允许"这一档**：DSH 的 outcome 值只有 `allowed-once` / `deny`
  /// （`user-approval/src/types.ts:32`），多一个按钮就是发明授权语义。
  final bool allowedOnce;
}

/// 通知权限 / 保活状态（原生如实报，不猜）。
class NotifyStatus {
  const NotifyStatus({required this.granted, required this.keepAlive});

  /// 通知权限开着没有（API 33+ 是运行时权限，**新装默认关**）。
  final bool granted;

  /// 前台服务此刻在不在跑。
  final bool keepAlive;
}

/// 平台端口。
abstract class NotifyPort {
  Future<NotifyStatus> status();

  /// 请求通知权限，返回**请求之后**的真实状态。
  Future<bool> requestPermission();

  /// 起前台服务（[title] / [text] 是常驻通知上的那两行）。
  Future<void> startKeepAlive({required String title, required String text});

  Future<void> stopKeepAlive();

  /// 贴一条通知；`false` = 贴不上（权限刚被吊销 / 平台拒绝）。
  Future<bool> show(AttentionNotice notice);

  Future<void> cancel(int id);

  Future<void> cancelAll();

  /// 跳到系统的渠道设置（**声音/震动归系统**，App 不改它们）。
  Future<void> openChannelSettings();

  /// 通知上按钮的答复流。
  Stream<NotifyApproval> get approvals;

  /// 收口（关掉 `approvals`）。
  Future<void> close();
}

/// 通知 id：**从内容算**，同一件事永远同一个 id。
///
/// 为什么算而不自增：`cancel(id)` 必须能凭内容找回同一条通知，而"已提醒过哪些"
/// 那份记录在 `AppModel` 里（派生、不落盘）。用 FNV-1a 32 位而不是
/// `String.hashCode` —— 后者不保证跨进程稳定。
int noticeIdOf(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  // 抬到常驻通知（1001）之上，避免撞 id。
  return 2000 + (hash % 100000000);
}
