/// **app 级单例**：整个进程只有一份、而不是每次装配一份的那几件事。
///
/// ## 为什么需要它
///
/// 通知端口（`core/notify.dart` 的 `NotifyPort`）天生是"每进程一个"的东西：
/// 安卓实现 `AndroidNotify` 在**构造时**就向 `dsh/notifications` 注册方法处理器，
/// 而同一条通道只认*最后*注册的那个
/// （`packages/flutter/lib/src/services/platform_channel.dart:578-593`）。
/// 于是"每次装配各建一个端口"的写法在第二台电脑上等于让先装配的那台
/// **永远收不到通知上的答复** —— 症状是"点了允许、没反应"，两端都没有异常也没有日志。
///
/// 现在端口在这里建一次、随 [AppServices] 注入**每一次**装配
/// （`main.dart` 的 `_assemble` 与 `_assembleWithoutCredentials` 都收这个参数），
/// `AppModel` 只*使用*它，不再自己造。
///
/// **前台服务不是第二个对象**：它就是同一条通道上的 `startKeepAlive` /
/// `stopKeepAlive`（`docs/subsystems/notifications.md` §6），所以这里不为它
/// 另立字段 —— 那会让"服务到底谁在管"有两个答案。
///
/// ## 它不做什么（不要在这里长出第二份判据）
///
/// "该不该提醒、提醒什么、什么时候撤"留在 `AppModel`（它持有唯一的状态：
/// 运行态 / 待处理集合 / 当前会话 / 前后台）；"要不要起前台服务"仍由
/// `AppModel._syncKeepAlive` 的三条判据算。这一层只回答**"端口是哪一个"**
/// 与**"谁负责关它"**。
///
/// 也**没有** `ownsNotifyLifecycle` 那种布尔标记：把"收尾归谁"做成一个开关，
/// 结果就是两边都以为自己不必收（外部 PR #8 的写法，注释写明"由装配层管"，
/// 而装配层并没有关）。生命周期归 app —— 所以 [dispose] 在这里，且只有这里。
///
/// ## 为什么住在 `data/`
///
/// 它不认识 Flutter，也不认识"这是不是安卓"：选择点仍在
/// `platform/notify_factory.dart`，由 `main()` 选好再传进来。端口是 `core/`
/// 的接口，`data/` 只负责"装配之后、平台之下"这一层 —— 三者方向都顺
/// （`docs/subsystems/app-platform-boundaries.md`）。
///
/// 取舍见 `.agents/notes/implemented/2026-11-06-s3-app-services.md`。
library;

import '../core/notify.dart';

class AppServices {
  AppServices({required this.notify});

  /// 通知与后台保活的**唯一**端口（`core/notify.dart` 的接口）。
  final NotifyPort notify;

  /// app 走了：收掉端口本身（注销 `dsh/notifications` 的方法处理器、
  /// 关掉 `approvals` 流）。
  ///
  /// **只有这里 close**：`AppModel.dispose()` 不关它 —— 关掉等于让还活着的那台
  /// 电脑的通知一起失效。反过来，"撤掉哪些通知、停不停前台服务"仍由
  /// `AppModel.dispose()` 发（它知道自己贴过什么），这里只管端口自己的收尾。
  Future<void> dispose() => notify.close();
}
