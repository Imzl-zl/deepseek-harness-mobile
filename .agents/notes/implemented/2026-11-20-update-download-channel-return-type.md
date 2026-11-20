# Agent Note: 通道返回值一律 `void` —— 一句 `as String?` 把下载变成了「type 'int' is not a subtype of type 'String?'」

Status: implemented

## Problem

用户 2026-11-20 的原话：

> 我这个手机 APP 更新下载报错 `type int is not a subtype of string` 啥玩意啊？？？怎么回事啊？？

点设置页「App 版本」查到新版、确认下载之后，界面弹的是：

```
下载失败：type 'int' is not a subtype of type 'String?' in type cast
```

这不是网络问题，也不是 GitHub 或系统下载器的问题 —— **下载根本没发出去**。

链路本来是这样的（2026-11-15 那一版，`54d6f08`）：

| 位置 | 写的是什么 | 实际是什么 |
|---|---|---|
| `DshAppUpdate.kt:48` | `result.success(enqueue(activity, url, fileName))` | `enqueue` 返回 **`Long`**（`DownloadManager.enqueue()` 的任务 id） |
| 过 `StandardMessageCodec` | — | `Long` → Dart **`int`** |
| `app_update_downloader.dart:52` | `invokeMethod<**String**>('download', …)` | 期望 **`String`** |

而 `MethodChannel._invokeMethod` 的最后一步是
`return codec.decodeEnvelope(result) as T?;`
（`packages/flutter/lib/src/services/platform_channel.dart:366`，同一文件 `:376-380`
的文档明写 "If it does not match the returned type of the channel, a TypeError will be
thrown at runtime"）。

于是每一次下载、在任何型号的手机上都必然抛
`type 'int' is not a subtype of type 'String?' in type cast`。

两个让这个 bug 活过三个版本（v0.2.18 / v0.2.19 / v0.2.20）的原因：

1. **它是 `TypeError`，不是 `Exception`**。`AppModel.downloadAppUpdate`
   （`app/lib/data/app_model.dart:277`）写的是 `on Object catch (error)` 后
   `error is Exception ? … : '$error'` —— 于是这段 Dart 内部错误被当成"失败原话"
   原样推到了 toast 上。调试期看代码时，`catch` 那一段看起来是"稳妥的"，实际是
   把内部错误伪装成业务错误。
2. **没有一条用例碰过这个通道的返回值**。`app_update_test.dart` 的下载用例
   注入的是 `downloadAppUpdate` **缝**（Dart 层函数），
   `pumpWidget` 之外的 `MethodChannel` 从没被真正调用过；
   `54d6f08` 的验证笔记也如实写了「**没有真机点过**」。

## Decision

**这一层不读返回值，就该声明 `void`**：`invokeMethod<void>('download', …)`。

准入门槛（可机械判定）：

1. `app/lib/platform/app_update_downloader.dart` 里对 `dsh/app-update` 的调用
   **泛型必须是 `void`**，不得写 `<String>` / `<Object?>` 去"接住"一个没人用的 id。
2. `app/test/app_update_download_test.dart` 钉住**三种返回值**（`int` / `null`）
   都能过，且 `result.error` 仍然抛成 `PlatformException`
   （"不读返回值" ≠ "吞掉失败"）。
3. 将来真要读任务 id（例如做"取消下载"）⇒ 显式改 `<int>`，并在原生侧保证
   不返回 `null`；那时第 2 条要一起改，**不允许**用 `Object?` 糊过去。

## Alternatives considered

1. **在 Dart 侧把泛型改成 `<int>`（照原生返回值写）**
   - 最强的理由：类型诚实，与 `DshAppUpdate.kt` 的签名严格对应；
     `DownloadManager.enqueue()` 契约上恒 `> 0`，写 `<int>` 不会错。
   - 为何被否：这一层**不读**那个 id（"入队即返回"，见文件头），声明一个必须
     与原生实现同步维护的类型，等于为一份没人消费的数据增加一处会漂的契约 ——
     而它漂掉时的表现，正是这次这个 bug。`void` 让"原生回什么"不构成失败，
     把错误从**形状上**消掉，而不是靠两侧人工对齐。
2. **在原生侧 `result.success(id.toString())` 把 id 转成字符串**
   - 最强的理由：一行改动，Dart 侧完全不用动，`<String>` 立刻成立。
   - 为何被否：治的是症状。这个 id 从头到尾没人读，转成字符串只是让一个
     无用的返回值"刚好能过 cast"；下一个通道还会踩同一脚。
   而且它把一个**平台数据**的形状迁就 Dart 侧的误声明。
3. **`invokeMethod<Object?>('download', …)`**
   - 最强的理由：任意返回值都能过，且不像 `void` 那样"看着像不关心"。
   - 为何被否：`Object?` 是"我确实要读它，只是先不转"的写法，会诱导下一个人
     真的去读一个垃圾 id；`void` 的语义与这一层的真实意图（fire-and-forget）一致，
     读它会在编译期就被拦。
4. **在 `AppModel.downloadAppUpdate` 的 `catch` 里匹配 `TypeError` 并翻译成人话**
   - 最强的理由：用户至少不会看到 Dart 内部错误，改动只在一处。
   - 为何被否：这正是本仓 `AGENTS.md` 的 Debug-First 明令禁止的方向 ——
     给一个**每次必现**的失败加一层好听的兜底，等于把"下载从来没成功过"
     这件事藏起来，让下一个版本继续坏。

## Consequences

- 收益：
  - 下载链路在 Dart 侧不再有任何"返回值形状"要求；原生回 id、回 null、将来回别的，
    都不会让下载失败。
  - `app/test/app_update_download_test.dart` 第一次真正驱动了 `dsh/app-update` 这条
    通道（此前只有缝的替身），并在**修复前**如实地红过一次
    （红得和用户报的错一模一样，含 `platform_channel.dart 366:41`）。
  - 同一模式有了判据：本仓其余通道（`dsh/notifications` 的 `startKeepAlive` /
    `cancel` / `cancelAll`、`dsh/photo-picker` 的注入点）本来就用 `void` 或 `Object?`，
    核对过与原生回值一致；`dsh/app-update` 是唯一的例外，现已对齐。
- 代价：
  - 想知道"系统到底收没受理"就看不到了（今天也不需要：`enqueue` 失败会抛，
    成功即入队）。
  - `AppModel.downloadAppUpdate` 里 `error is Exception ? … : '$error'` 那个分支
    依然存在，仍会把**别的** `Error` 当业务原话念给用户。这次没动它：
    它没有在这次事故里起作用，改它属于另一件事（并且要先想清楚 `Error` 该不该
    被吞）。**这一条是已知的剩余风险**，不是"已经解决了"。
  - 仍然**没有真机点过**：`DownloadManager` 落盘、通知、点开即安装这三跳的证据
    依旧是系统组件的行为，本次只证明了"请求确实发出去了、不再被类型转换挡下"。
