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
/// ## 前台服务为什么也在这里
///
/// 它不是第二个对象（就是同一条通道上的 `startKeepAlive` / `stopKeepAlive`，
/// `docs/subsystems/notifications.md` §6），但它**是 app 级的**：一条服务、
/// 多台电脑各有各的诉求。原来的写法是每个模型各自读 `status().keepAlive` 再决定起停，
/// 两台时就会抖动 —— A 在服务态、要保活 ⇒ 起；B 掉线、不要 ⇒ 立刻停，
/// 于是 A 的保活被 B 的结论撤销。所以"起还是停"只在这里算**汇总**（见
/// [syncKeepAlive]）。
///
/// ## 它不做别的判断
///
/// "该不该提醒、提醒什么、什么时候撤"留在 `AppModel`（它持有唯一的状态：
/// 运行态 / 待处理集合 / 当前会话 / 前后台）。这一层只回答**"端口是哪一个"**、
/// **"这条服务要不要在跑"**与**"谁负责关它"**。
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
/// 取舍见 `.agents/notes/implemented/2026-11-06-s3-app-services.md` 与
/// `2026-11-06-s4-host-sessions.md`。
library;

import '../core/notify.dart';

/// 常驻通知上的两行。
///
/// **不承诺"连接还在"**：进程会被系统冻结 / 被 ROM 杀掉，那时这句话就是假的
/// （2026-10-24 真机实测，见 `docs/subsystems/notifications.md` §2）。
const String kKeepAliveTitle = 'DeepSeek Harness';
const String kKeepAliveText = '后台保活已开启';

/// [AppServices.syncKeepAlive] 的结论：两个都是**平台真值**。
typedef KeepAliveState = ({bool granted, bool keepAlive});

class AppServices {
  AppServices({required this.notify});

  /// 通知与后台保活的**唯一**端口（`core/notify.dart` 的接口）。
  final NotifyPort notify;

  /// 每个装配实例对"要不要保活"的**当前**诉求（键 = 那台的 `hostId`；没配对是空串）。
  ///
  /// 语义是"谁此刻在要"，不是计数：同一个模型反复报只留最后一次。
  /// 一条服务、多台电脑 —— **只要还有人在要就留着**，最后一个也不要了才停。
  final Map<String, bool> _keepAliveWants = <String, bool>{};

  /// 串行链：装配层一次广播会让几台**同时**进来，而"读 status → 起/停"中间有
  /// `await`，交错就会重复起服务。排成一条链，每次读到的都是上一次的落点。
  Future<void> _keepAliveTail = Future<void>.value();

  /// 后台保活（前台服务）的**唯一开关处**。
  ///
  /// [want] 由 `AppModel` 按它那两条判据算（在后台 + 连接在服务态）；
  /// 第三条"系统给了通知权限"是设备级事实，在这里读一次 ——
  /// 没权限还起服务 = 一条看不见的常驻通知 + 白耗电（平台原文，见
  /// `docs/subsystems/notifications.md` §1）。
  ///
  /// 返回读到的真值；调用方（`AppModel`）用它决定要不要把连接**真的**断掉
  /// （服务停了而连接还在，就是"看不见的长连接"，比断开更糟）。
  Future<KeepAliveState> syncKeepAlive(String of, {required bool want}) {
    if (want) {
      _keepAliveWants[of] = true;
    } else {
      _keepAliveWants.remove(of);
    }
    // `run` 把错误如实交给调用方；链本身要能继续（不然后续的模型永远排队）。
    final run = _keepAliveTail.then((_) => _reconcileKeepAlive());
    _keepAliveTail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<KeepAliveState> _reconcileKeepAlive() async {
    final status = await notify.status();
    final shouldRun = _keepAliveWants.isNotEmpty && status.granted;
    if (shouldRun && !status.keepAlive) {
      await notify.startKeepAlive(title: kKeepAliveTitle, text: kKeepAliveText);
      return (granted: status.granted, keepAlive: true);
    }
    if (!shouldRun && status.keepAlive) {
      await notify.stopKeepAlive();
      return (granted: status.granted, keepAlive: false);
    }
    return (granted: status.granted, keepAlive: status.keepAlive);
  }

  /// app 走了：撤掉全部通知、停掉前台服务、收掉端口本身
  /// （注销 `dsh/notifications` 的方法处理器、关掉 `approvals` 流）。
  ///
  /// **只有这里 close 端口**：`AppModel.dispose()` 不关它 —— 关掉等于让还活着
  /// 的那台电脑的通知一起失效。它也只报"我不再需要保活了"，不直接停服务。
  Future<void> dispose() async {
    _keepAliveWants.clear();
    await notify.cancelAll();
    await notify.stopKeepAlive();
    await notify.close();
  }
}
