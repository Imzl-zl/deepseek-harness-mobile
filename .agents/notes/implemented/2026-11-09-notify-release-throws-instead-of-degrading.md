# Agent Note: 非 Android 的 release 构建必须装配失败，不能静默换成内存通知

Status: implemented

## Problem

`createNotifyPort()` 原来是一行三元式：安卓给 `AndroidNotify()`，其余一律 `MemoryNotify()`。

桌面调试确实需要那条回落（`flutter run -d windows` 没有通知实现）。但同一个表达式也覆盖了
**iOS / 鸿蒙的 release 构建**：那两个端的通知实现还没落地，装出来的包里 `notify` 永远是一条
把调用记进内存的假端口 —— 手机上没有一条提醒，日志、异常、界面全都正常。这类"功能不存在"
比崩溃难查得多，因为没有任何东西会失败。

## Decision

装配点按宿主与构建模式三分，判断只用**编译期常量**：

1. `Platform.isAndroid` → `AndroidNotify()`；
2. 非 Android 且 `!kReleaseMode` → `MemoryNotify()`（桌面调试）；
3. 非 Android 且 `kReleaseMode` → `throw UnsupportedError(...)`。

准入门槛（可机械判定）：

1. `lib/platform/notify_factory.dart` 里 `kReleaseMode` 必须真的出现在分支条件中（`if (kReleaseMode)`），只 `import` 不算守卫。
2. `MemoryNotify()` 的位置必须在 `throw UnsupportedError` 之后 —— 也就是只在 debug 那一支可达。
3. 不许出现 `fromEnvironment` 与自定义 `final bool`：release 与 debug 的差别必须是编译期事实，不是一次配置读取。
4. 判据是源码形状断言（`test/assembly_invariants_test.dart`）。行为测试不可得：`kReleaseMode` 是编译期常量，`flutter test` 只跑 debug，`if (kReleaseMode)` 那一支在本进程里根本不存在。

## Alternatives considered

1. 保持"一律回落 `MemoryNotify`"
   - 最强的理由：代码最少，桌面/未来端调试永不因缺实现而崩。
   - 为何被否：release 的 iOS/鸿蒙包上通知静默消失，且没有任何失败信号 —— 这正是要禁的那类"假成功"。
2. 只在 debug 打一行警告（`assert` / `debugPrint`）后继续回落
   - 最强的理由：release 不崩，用户至少还能用别的功能。
   - 为何被否：警告只在开发期可见；用户侧看到的仍然是"提醒没了"。而且 `debugPrint` 在 release 里通常被裁掉，等于没写。
3. 用运行时变量分流（`bool.fromEnvironment('dart.vm.product')` 或一份平台配置）
   - 最强的理由：可以在测试里注入假判断，于是"release 会抛"能写成行为测试。
   - 为何被否：那会把编译期事实降级成可被读错的配置，坏的形态从"忘记实现"变成"配置写错"。不可测的根因是 `flutter test` 只有 debug，不是 `kReleaseMode` 本身；为可测性改产品判断是本末倒置。
4. 现在就把 iOS / 鸿蒙的通知实现补上
   - 最强的理由：真正解决问题，而不是让构建失败。
   - 为何被否：那是三端能力包的量级，且没有第二台真机/iOS 设备可验；这一批的目标是先把"静默降级"关掉，让缺口以显式失败的形式暴露。

## Consequences

- 收益：release 的非 Android 包在装配时立刻失败，错误信息直接说明"没有通知实现、不许回落"；"提醒消失但一切正常"这种形态不再存在。
- 代价：iOS / 鸿蒙的 release 构建**目前装配即抛**，在那两个端的实现落地前，release 只对 Android 有意义。桌面调试必须用 debug 构建（`flutter run -d windows` 默认即 debug）。
- 代价：这条不变量只能靠源码形状断言守。若把工厂改写成等价但不同形状（例如 `switch` 表达式），测试会误报 —— 正确做法是同步改测试，而不是放宽断言。
