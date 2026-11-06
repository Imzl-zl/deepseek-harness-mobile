# S3：AppServices —— 通知端口是 app 级单例

- 日期：2026-11-06
- 触发：架构审查（`proposed/2026-11-06-branch-a-and-pr-audit.md` §四）的 S3；
  S4（按 hostId 池化 `AppModel`）的前置。
- 状态：implemented

## Problem

通知端口（`core/notify.dart` 的 `NotifyPort`）在装配点**每次装配新建一个**：
`main.dart` 的 `_assemble` 里写 `notify: createNotifyPort()`。单台电脑时看不出问题，
但它有两个已经在盘上的后果：

1. **端口是"每进程一个"，而装配是"每台电脑一次"**。安卓实现 `AndroidNotify` 在
   构造时就向 `dsh/notifications` 调 `setMethodCallHandler`，而 `MethodChannel`
   只认*最后*注册的那个处理器
   （`packages/flutter/lib/src/services/platform_channel.dart:578-593`）。
   S4 让两台电脑同时在池子里之后，第二次装配会把第一次注册的处理器顶掉 ——
   先装配的那台**永远收不到通知上的答复**，症状是"点了允许、没反应"，
   两端都没有异常也没有日志。这正是本仓最贵的一类 bug（静默失败）。
2. **没人关端口**。`NotifyPort.close()`（注销方法处理器 + 关 `approvals` 流）
   在 `app/lib` 里**零调用点**：`AppModel.dispose()` 撤通知、停前台服务，但不关端口。

## Decision

1. **新建 `data/app_services.dart` 的 `AppServices`**，持有唯一那个 `NotifyPort`，
   并给出唯一的关闭点 `dispose() → notify.close()`。
2. **`main()` 建一次**：`runApp(DshMobileApp(services: AppServices(notify: createNotifyPort())))`。
   根部 State 拿它、在 `dispose` 里调 `services.dispose()`。
   `createNotifyPort()` 之前必须 `WidgetsFlutterBinding.ensureInitialized()` ——
   `setMethodCallHandler` 断言绑定已初始化（`platform_channel.dart:587-593`），
   而 `runApp` 的**实参先求值**，那时还没有绑定。
3. **装配只注入**：`_assemble(services, credentials, …)` 与
   `_assembleWithoutCredentials(services, …)` 都把 `services` 作为必填参数收下，
   写 `notify: services.notify` —— 忘不了（少传一个参数编译就不过）。
4. **没配对那条装配也拿到同一个端口**。此前它根本不传 `notify`（不是"又建一个"，
   是完全没有）。现在它有端口，于是退到后台时也会对齐前台服务
   （`setAppForeground` → `_syncKeepAlive`：状态不是 `serving` ⇒ 不起服务）；
   它不 `start()`，所以不贴提醒。
5. **前台服务不另立对象**：它就是同一条 `dsh/notifications` 通道上的
   `startKeepAlive` / `stopKeepAlive`（`docs/subsystems/notifications.md` §6）。
   为它再开一个字段就是"服务谁在管"有两个答案。
6. **IME 高度这次不搬**：本分支没有任何代码读键盘高度（`app/lib` 里 `viewInsets`
   零引用，键盘让位由 `Scaffold.resizeToAvoidBottomInset` 完成）。搬一个没人读的
   字段进来就是死代码。真需要它时（宿主与外部的两条路都被否过，见下）它归这里。

## 被否掉的

- **`ownsNotifyLifecycle: false` 布尔标记**（外部 PR #8 的写法）：装配层传 `false`
  表示"端口不归你收"，结果装配层自己并没有收 —— **没有任何人 cancel**。
  生命周期归 app 就把关闭点放在 app（`AppServices.dispose`），不用开关表达。
- **让 `AppModel` 自己持有并关闭端口**：关掉等于让另一台电脑的通知一起失效；
  且"谁最后走谁关"没有判据（S4 之后同时有几台是用户的事）。
- **把 S4 的"撤哪些通知/停不停服务"一起搬过来**：单实例时两者等价，而多实例的
  判据（移除某一台不能动别台的通知与服务）**要有池化才测得出**。搬过去却没有
  对应测试 = 一次无人验证的行为改动。留给 S4 与它的三条验收一起做。
- **IME 高度按 PR #4 的路子（`viewInsets.bottom` 取键盘高度）**：那条路真机实测
  键盘态下恒 0，已被否（`proposed/2026-11-06-branch-a-and-pr-audit.md` 的 #4 行）。

## 代价与已知边界

- 端口从"装配的产物"变成"app 的产物"，于是**它比 `AppModel` 活得久**：
  换电脑/重新配对时端口不重建，`approvals` 流不重连 —— 这正是要的（原生回调只该有一条）。
- `AppModel.dispose()` 仍发 `cancelAll()` + `stopKeepAlive()`。单实例时与之前完全一致；
  **S4 池化后这两句必须搬走**（移除 B 不能撤掉 A 的通知、不能停 A 需要的服务），
  而那时才有对应的测试。
- `dsh/notifications` 的方法处理器现在只在 app 退出时注销；进程被杀时不执行
  （与之前一致，Android 会连进程一起收）。

## 验证

- `cd app && dart analyze --fatal-infos lib test`：No issues found。
- `cd app && flutter test`：全量通过（新增 `test/app_services_test.dart` 2 项，
  `test/assembly_invariants_test.dart` 加 1 项）。
  - 「两次装配拿到同一个端口」的判据是**行为的**：两个 `AppModel` 各贴一条提醒，
    两条都落在同一个 `MemoryNotify` 的 `visible` 里。各建一个端口时这里只剩一条。
  - 「模型释放不关端口」：`app.dispose()` 之后 `approvals` 流仍能收事件；
    `services.dispose()` 之后同一操作抛 `StateError`（端口真的关了）。
- **变异校验**（两条，各跑一次）：
  1. 把 `_assemble` 里的 `notify: services.notify` 改回 `createNotifyPort()` ⇒
     `assembly_invariants_test` 立刻报 `Expected: <1> Actual: <2>`；还原后全绿。
  2. 把 `AppServices.dispose()` 改成空实现 ⇒ `app_services_test` 的
     `throwsStateError` 断言变红（`Actual: <Closure>`）；还原后全绿。
- 真机：本批不改任何可见行为（单台电脑的端口数量 1 → 1），未单独装机验收；
  S4 的双机验收会一并覆盖"通知还能答"。
