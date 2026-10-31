# Agent Note: Android `namespace` 与 `MainActivity` 包名对齐

Status: implemented

## Problem

`bc284bd`（发布准备）把 `applicationId` 从 `com.example.dsh_mobile` 改成
`io.github.imzlzl.dsh_mobile`，同时把 `namespace` 一起改了；但 Kotlin 源码还留在
`app/src/main/kotlin/com/example/dsh_mobile/`，五个文件的 `package` 声明也仍是
`com.example.dsh_mobile`。

清单里三个组件写的是相对名（`android:name=".MainActivity"`、`.DshForegroundService`、
`.DshActionReceiver`），AGP 按 `namespace` 展开成
`io.github.imzlzl.dsh_mobile.MainActivity` —— APK 里没有这个类，于是启动即崩：

```
FATAL EXCEPTION: main
java.lang.RuntimeException: Unable to instantiate activity ComponentInfo{
  io.github.imzlzl.dsh_mobile/io.github.imzlzl.dsh_mobile.MainActivity}
Caused by: java.lang.ClassNotFoundException: Didn't find class
  "io.github.imzlzl.dsh_mobile.MainActivity"
```

现场证据（2026-10-31 真机 `23113RKC6C`，`adb logcat -b crash`）：装完点图标立刻回桌面，
`pidof` 为空。设备上两个包并存：`com.example.dsh_mobile`（2026-10-27 首装、有配对数据）
与 `io.github.imzlzl.dsh_mobile`（2026-10-31 首装、从未成功启动过）。

## Decision

**把源码目录与 `package` 声明一起迁到 `io.github.imzlzl.dsh_mobile`**，而不是把清单里的
相对名改写成全限定名，也不是把 `applicationId` 退回 `com.example`：

- `app/src/main/kotlin/io/github/imzlzl/dsh_mobile/*.kt`（五个文件），`package io.github.imzlzl.dsh_mobile`。
- 清单一个字符不改：相对名 + `namespace` 是 AGP 的标准形态，跟着包名走即可。
- 通知动作串（`com.example.dsh_mobile.ALLOW_ONCE` 等）**保持原样**：它们是
  本 App 内部"通知按钮 → 广播接收器"之间的名字，没有外部消费者；改名只会让
  升级前挂着的通知点了没反应。

## Alternatives considered

1. **清单改成全限定名 `android:name="com.example.dsh_mobile.MainActivity"`**
   - 最强理由：改三个字符串就完事，不动目录、不动 `package`，风险面最小。
   - 为何被否：`namespace` 与源码包名长期不一致，`R` 与 `BuildConfig` 的解析路径从此
     需要"记住这里对不上"；下一个往清单加组件的人还会再踩一次（相对名继续按
     `namespace` 展开）。一次迁干净，之后只有一套名字。
2. **把 `applicationId`/`namespace` 退回 `com.example.dsh_mobile`**
   - 最强理由：能原地升级用户手上那个**已配对**的 App，配对凭据不丢。
   - 为何被否：`bc284bd` 是有意改的（发版身份，`applicationId` 一旦发版就锁定），
     退回去等于推翻发版决定；而且真正的问题从来不是包名，是源码没跟上。
     代价（新包名 = 另一个 App、要重新配对）属于那次发版决定的既有代价，本笔记不改它。

## Consequences

- 收益：debug APK 能启动；三个组件（Activity / Service / Receiver）的相对名都能正常解析；
  包名与源码目录此后只有一套真值。
- 代价：设备上仍是两个 App。`io.github.imzlzl.dsh_mobile` 是全新安装（无配对数据），
  要看到真实会话得重新扫码；`com.example.dsh_mobile` 里那份配对随旧包留着。
- 代价：既有通知动作串保留 `com.example` 前缀，读代码时会看到一个"过时的名字"，
  这里已写明它为什么不改。

## Testing

- `adb logcat -b crash` 不再出现 `ClassNotFoundException`；`adb shell pidof` 有进程；
  截图里能看到主界面（"还没配对"落地页）。
- `cd app; flutter build apk --debug` → `adb install -r build\app\outputs\flutter-apk\app-debug.apk`
  （`adb install -r` 原地替换，不卸载；`flutter install` 会先卸载并清掉配对凭据，见 `tools.md`）。
