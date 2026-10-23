# Agent Note: 通知能力（后台保活的真实可行性）+ 五条界面短板的落地口径

Status: proposed（**0 行代码**；方案待点头。事实与判据已逐条落到出处，缺证据的地方写"待量"）

## 0. 一句话结论

通知的第一约束**不是"要不要保活"**，而是四道系统门 + **一条我们自己写的规则**：`POST_NOTIFICATIONS`
（本机现在是 `ignore`）、前台服务类型（`remoteMessaging` 无时限）、启动时机（"从用户可见态转入后台"是例外）、
渠道（声音/震动归系统）。四道门都能过；真正拦住我们的是契约 §13 的"三端都不做后台长连接"——
**那是本仓自己的产品决定，不是平台限制，也不是 DSH 的语义**。所以它是**补通道**，不是替宿主做决定；
但它必须收窄成**"跑动中保活"**（不是常驻），否则代价与噪音都不成立（§3 有被否理由）。

**成本口径（2026-10-24 更正，用户当场指出"通知很成熟"）**：§1.2 那五道门**不是拦路虎** —— 每条都是一次性的
登记动作（两个权限 + 一个 manifest 属性 + 一个类型 + 一个渠道），全部加起来的平台侧代码 ≈ 一条 Service
（~120 行 Kotlin）与一个 Dart 端口（~150 行）。**通知本身不贵**。贵的是**它的触发源**：三类触发全都来自那条
连接，而我们现在切后台就把连接断掉（§1.3）。所以这条决策的**唯一问题**是"要不要让 App 在后台保留一条连接"，
不是"通知难不难做"。初版把门做成表格、读起来像在论证"做不了"，是本篇的表述失误。

## 1. 事实（每条带出处）

### 1.1 设备与构建面（本机实测，不是假设）

| 事实 | 出处 |
|---|---|
| 设备 Android **16 / API 36**，`OS3.0.306.0.WNKCNXM`，机型 `23113RKC6C` | `adb shell getprop ro.build.version.release/ro.build.version.sdk/ro.build.version.incremental/ro.product.model`（2026-10-24 原文） |
| 本 App `targetSdk = 36`、`compileSdk = 36`、`minSdk = 24` | `app/android/app/build.gradle` 用 `flutter.targetSdkVersion`；默认值见 `D:\soft\flutter\packages\flutter_tools\gradle\src\main\kotlin\FlutterExtension.kt:23,26,34` |
| 本机只有 `platforms/android-35`、`android-36` 两套平台；且带 `android-stubs-src.jar`（可逐行引） | `Get-ChildItem D:\soft\android-sdk\platforms` |
| 现在**发不出任何通知**：`POST_NOTIFICATION: ignore`；`dumpsys package` 里没有 `POST_NOTIFICATIONS` 条目；`dumpsys notification` 里本包**零渠道** | `adb shell cmd appops get com.example.dsh_mobile` / `dumpsys package` / `dumpsys notification`（2026-10-24） |
| App 不在电池优化白名单；本机存在 `com.miui.powerkeeper` / `com.xiaomi.joyose` / `com.miui.securitycenter` | `adb shell dumpsys deviceidle whitelist`、`pm list packages` |
| 本包 manifest **只有 CAMERA**，没有任何 service/receiver | `app/android/app/src/main/AndroidManifest.xml` |

> 纪律：先看系统侧（appops / 渠道列表），再怀疑 App 接线 —— 这三条系统侧证据说明"没命中"的原因是
> **从未实现**，不是"实现了但被拦"。

### 1.2 Android 侧硬规则

| # | 事实 | 出处 |
|---|---|---|
| 门1 | `POST_NOTIFICATIONS` 是**运行时权限**；targetSdk≥33 的新装应用**通知默认关**；用户拒绝后"仍能在 Task Manager 看到前台服务通知，但**通知抽屉里看不到**" | <https://developer.android.com/develop/ui/compose/notifications/notification-permission>（"Declare the permission" / "Effects on newly-installed apps" / "Exemptions" 三段）；常量 `android/Manifest.java:482` |
| 门2 | Android 14+ **必须**在 manifest 声明类型 + 申请对应权限，并在 `startForeground(id, n, type)` 传类型 | <https://developer.android.com/develop/background-work/services/fgs/service-types> 首段；本机枚举 `platforms/android-36/data/res/values/attrs_manifest.xml:1705-1866` |
| 门2a | **`remoteMessaging`（0x200）**：唯一一条对得上"设备间消息接力"的类型 —— 平台原文 *"Messaging use cases which host local server to relay messages across devices"*（`attrs_manifest.xml:1824-1829`），文档描述 *"Transfer text messages from one device to another. Assists with continuity of a user's messaging tasks when they switch devices."*；只需 `FOREGROUND_SERVICE_REMOTE_MESSAGING`（`Manifest.java:230` 的拼写核对见 `ServiceInfo.java:76`），**无运行时前置** | 同上 service-types 页 "Remote messaging" 段 |
| 门2b | **`dataSync`（0x01）应主动避开**：平台在属性文档里直接写 *"For apps with targetSdkVersion UPSIDE_DOWN_CAKE and above, this type should NOT be used"* | `attrs_manifest.xml:1709-1716` |
| 门2c | `specialUse`（0x40000000）无时限，但要 `<property android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE">`，且"这些值会在 **Google Play Console** 提交时被审核" —— **审核是 Play 政策，不是 OS 限制**；本仓侧载分发，不走 Play（如实记录：仍属"语义不诚实"的兜底，不当首选） | service-types 页 "Special use" 段 + "Google Play policy enforcement" 段 |
| 门3 | **只有 `dataSync` 与 `mediaProcessing` 有时限**：24 小时内累计 6 小时（两者各算），到期调 `Service.onTimeout(int,int)`，几秒内不 `stopSelf()` 就抛 `RemoteServiceException`；额度用尽后再启动抛 `ForegroundServiceStartNotAllowedException`（"Time limit already exhausted…"），除非用户把 App 带回前台（重置计时） | <https://developer.android.com/develop/background-work/services/fgs/timeout>；签名 `android/app/Service.java:53,55` |
| 门4 | targetSdk≥31 **不能从后台启动**前台服务；例外之一是 **"Your app transitions from a user-visible state, such as an activity"**；另一条是"用户关掉了电池优化" | <https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start> |
| 门5 | 渠道一经创建，**声音/震动/重要级归用户**，App 改不了；App 能做的是**读**（`getImportance/getSound/getVibrationPattern`）与**把用户送到系统渠道设置**（`ACTION_CHANNEL_NOTIFICATION_SETTINGS`） | <https://developer.android.com/develop/ui/compose/notifications/channels>（三处原文）；`android/app/NotificationChannel.java:49,60,65,67,69` |
| 门6 | WorkManager 周期任务**最小 15 分钟**，且"受 OS 电池优化（如 doze）影响可能延迟" | <https://developer.android.com/reference/androidx/work/PeriodicWorkRequest>（*"Periodic work has a minimum interval of 15 minutes."*） |
| 门7 | targeting 36 的行为变更页**没有任何前台服务/通知条目**（逐节读完：edge-to-edge、预测性返回、固定频率调度、大屏自适应、健康权限、蓝牙、安全、隐私）。唯一相关的未来项是 **Local Network Permission**（当前 opt-in，需 `am compat enable RESTRICT_LOCAL_NETWORK`），**将来会影响直连拓扑** —— 本轮不动，记进 §15 | <https://developer.android.com/about/versions/16/behavior-changes-16> |
| 通知按钮 | Action + `RemoteInput` 都在平台里（`Notification.Action` `Notification.java:359`、`Action.Builder` `:417`、`addRemoteInput` `:430`） | 本机 stub |

### 1.3 本仓现状（读出来的，不是猜的）

- **切后台断连**：`app/lib/core/sync_client_impl.dart:1152-1169`。先 `_sendHello()` 报 `background`（`:1159-1161`），
  再 `_disconnect()`（`:1163`），注释原文就是"§2.2 / §13"。
- **心跳只差一条判断**：两侧 `tick()` 都把**半开判定放在前台判断之前**
  （`app/lib/core/keepalive.dart:78-80`、`connector/src/transport/keepalive.ts:70-72`）⇒ 后台只是**不发 ping**，
  半开照判（2 个周期 = 120 s 就关）。**"保活"要动的只有 `if (!_foreground)` 那一条**，不是一套新的心跳策略。
- **电脑侧的 `setForeground` 零生产调用点**：全仓只有 `connector/tests/transport.test.ts:71,94,96`。
  ⇒ "后台不推 / 后台不发心跳"在**电脑侧从未生效**，它一直是"手机自己断开"的副产品。
  这既是**要删的死码**，也是"保活不需要改电脑侧"的证据。
- **协议里早就有后台态**：`sync.hello.app = 'foreground' | 'background'`（契约 §5.4）、`presence.app`（§3 帧表 :122）、
  §9 那句"心跳仅在**前台**且连接空闲时"。⇒ 后台连接**不是新语义**，是"写在协议里、被 §13 禁止使用"的分支。
- **零通知代码**：`app/lib` 里 `notif` 只命中 `ChangeNotifier`；pubspec 无通知插件；manifest 无 service/receiver。
- **能力包目录在磁盘上不存在**：`app/packages/` 缺失，现实只有 `app/lib/platform/`（10 个文件）与 `app/lib/ui/`（33 个文件，无 `adaptive/` 子目录）。
  `docs/subsystems/app-platform-boundaries.md` §1 画的那五个包（`notify` / `live_surface` / `keepalive` …）是蓝图，不是现状。
- **三类触发源全部在手**：`status` 帧（§3 :119-120）→ `app_model.dart:1915-1928` 的 `_setRunning`；
  `approval/asked`；`ask_user_question` 的 `tool/call`（`app/lib/data/projection.dart:1020-1033`）；
  待处理计数 `_pendingCountOf`（`app_model.dart:2497`）。**没有一条要新造**。

### 1.4 DSH 原生的"运行中 / 完成"（这条改写了短板 #1 的做法）

| 事实 | 出处（DSH 仓库，只读） |
|---|---|
| 会话行状态是**四态带优先级**：`pendingInteraction`（approval / plan-review / question，`warning`）> `running`（`ongoing`）> `runningSubagentCount>0`（追加第二枚 `ongoing`）> `completed`（`done`）> `idle` | `packages/client/ui-workspace/src/client/rows/Rows.tsx:344-398` |
| 只画第一枚点，其余状态进看不见的读屏文本 | `Rows.tsx:400-410` |
| `ongoing` 是**转圈**，`done`/`warning`/`idle` 是实心点（`done` 在 step 形态里是勾） | `packages/client/ui-primitives/src/StateDot.tsx:44-77` |
| "完成" = `completionUnread` | `ui-workspace/src/client/tree.ts:412,614`（`completed: status?.completionUnread === true`） |
| 它是**浏览器本地**派生量：一个 `Set`，`running` 变 `false` 且**不在主视图里**才置位，`running` 变 `true` 清掉；在主视图里的会话每轮基线扫描都清掉 | `packages/client/ui-session/src/client/index.ts:292,490-498,511,517` |
| 字段注释原文：*"Whether an observed stop outside the main view still needs acknowledgement."* | 同上 `:65-66` |

> **结论**：DSH 的"点进去消失"**不是本地已读表**，而是"它是**不是正在主视图里**"的派生；**不落盘**。
> 手机上的对应物 = "App 在前台 **且** 抽屉当前选中的就是它"。⇒ 短板 #1 从"要新建一份存储"降成
> "一个派生函数"，同时天然满足"单一真值"。这是本条最值钱的发现：**用户的直觉（要落盘）会被宿主语义否掉**。

## 2. 三方案对照

| | **A 前台服务保活（收窄版：跑动中保活）** | **B 推送（FCM / 厂商）** | **C 只做 App 内** |
|---|---|---|---|
| 语义 | 有跑动中的回合且 App 退到后台 ⇒ 起前台服务（`remoteMessaging`）保住**同一条**连接；回合收口即停 | 服务端发现事件 ⇒ 系统推送通道敲门 | 不碰连接：抽屉四态点 + 前台里的站内提示 |
| 补通道 / 替决定 | **补通道**（我们的链路缺"App 不在前台仍在这条会话上"） | 补通道，但要**新基础设施**（推服务器 + 每端 SDK） | 补 UI，不改语义 |
| 平台门 | 门1 通知权限 + 门2 类型 + 门4 启动时机（全部可过，见 §1.2） | 每家厂商的账号/模板/分类/限额；国内无 GMS 假设下要接 1–4 家 | 无 |
| 契约影响 | §13 / §2.2 / §9 三处散文（**帧与协议零改动**） | §15 要整段重写 + 方法表加 `push.configure` + 公网服务端 | 零 |
| 代价 | 常驻通知（仅回合期间）、耗电待实测、ROM 杀进程不可控 | 服务端运维 + 4 家 SDK + 审核/限额；仍然"丢就丢"（§9 只承诺"敲门"） | 只覆盖"App 在前台" |
| 判据 | **推荐**（收窄版） | **不做**（§3） | **推荐，且与 A 同批**（它的核心是四态点，不是"通知"） |

**判据回答（用户的三问原样）**

- **哪一条是补通道**：A。DSH 没有"前台/后台"这个概念（`sync.hello.app` 是**我们自己**加的），
  §13 那句"三端都不做后台长连接"是**本仓的产品决定**，不是平台限制、也不是宿主语义。
- **哪一条是替宿主做决定**：把"完成"做成新的状态机、给通知加超时/去重表/优先级档位、自己造一套"震动开关"、
  给提问做通知内多选答题 —— **这四件都不能做**。下面每条都点名了它为什么是"替决定"。
- **触发源**只有三条，且都是既有语义：`status` 帧的 `running` 边沿、`approval/asked`、提问的 `tool/call`。
  **不新造"完成"事件**。

## 3. 被否方案（先写它最强的理由，再写为什么否）

### 3.1 常驻长连接（用户原文的 A，不加收窄）

**最强理由**：只有它能不漏任何事件 —— 包括**定时任务 / 工作流**在没人操作时起的那一轮。
"跑动中保活"覆盖不到那种"我什么都没干，但电脑上有个任务跑起来了"的情形。

**为什么否（可作为二期）**：

1. 常驻通知是**永久噪音**，而收益只在极少数时刻兑现；
2. 若用 `dataSync`，6h/24h 额度会把它变成"某天跑够 6 小时就不许再起"；若用 `remoteMessaging`，
   则要长期占着一个为 IM 连续性设计的类型；
3. **它不扩大触发面**：三类触发（审批 / 提问 / 回合收口）在没有 `running` 时**不可能发生** ——
   `running` 的语义本身涵盖"等工具 / 等审批"（`core/agent/src/runtime-types.ts:102-109`，见
   `implemented/2026-10-24-running-from-native-status.md` 的引文）。定时任务起的轮次同样把 `running` 置真，
   但那一刻我们**没有服务**（App 在后台、无连接）⇒ 这是"跑动中保活"的**已知缺口**，写进 §15，
   不能用"常驻"去换一个"也许能赶上"的赌注。

### 3.2 B 推送

**最强理由**：这是**唯一**在 App 被强杀、甚至没启动时仍能送达的路（契约 §13 已核实的 iOS/鸿蒙原文），
也是唯一不耗电、不需要常驻通知的路。

**为什么否**：

1. 本仓**没有推送服务端**，也没有公网身份；FCM 要 Firebase 工程 + 服务端凭据 + 设备有 GMS
   （本机确有 `com.google.android.gms`，但"国内 ROM 无 GMS"是 §13 的前提，不能靠本机一台机器的运气立方案）；
2. 厂商通道要逐家接：每家一套账号 + 模板 + 分类报备 + 限额（契约 §13 已核实的规则：
   小米 2026-07-01 起私信必须带 `channel_id` + 模板 ID；vivo 运营消息仅 7:00–23:00；鸿蒙未申请自分类权益
   默认静默且每日 2 条）。**失败面 = 4 家各自的 token / 限额 / 审核 × 个人工具的 2 台设备**；
3. 即使接完，正确性仍靠"回前台补课"（§9：推送只负责敲门）—— 花的是基础设施的钱，买的是"可能早 10 秒"。

⇒ **不做**。理由写进 §15（保持"可复核"，不是"以后再说"）。

### 3.3 WorkManager 轮询

**最强理由**：不需要常驻通知、不占前台服务类型、不需要通知权限。

**为什么否**：

1. **最小 15 分钟**且受 doze 延迟（§1.2 门6）—— 对"有人正等审批"这个场景等于没有；
2. 没有推送服务端时它**只能盲轮询**：连上才知道有没有活，而"连上"就是 A 已经在做的事 ⇒ 花同样的钱、换更差的延迟；
3. 它会引入一份"上次看到哪"的落盘状态 ⇒ **第二真值**（本仓最不能碰的东西）。

### 3.4 App 内再造"震动开关"

**最强理由**：用户想要"别响，只要角标"。

**为什么否**：渠道创建后**声音/震动/重要级由系统完全控制**（§1.2 门5）—— App 里再造一个开关，
必然与系统设置**不一致**（用户关掉系统渠道声音、我们开关还显示"开"）。**系统已经给出答案**
（三问①：删掉我们的开关，DSH/平台会不会已经给出答案？会）。
正确形态：设置页放**一行入口**跳到该渠道的系统设置（`ACTION_CHANNEL_NOTIFICATION_SETTINGS`），
开关本身留给系统。

## 4. 方案 A 的形状（收窄版，待点头）

| 项 | 定值 | 依据 |
|---|---|---|
| 何时起 | `setAppState(background)` **且** `_runningSids` 非空 | 门4 的"从可见态转入后台"例外；`_runningSids` 是宿主 `status` 的投影 |
| 何时停 | `_runningSids` 变空；或回前台（回前台继续复用同一条连接，只停服务） | 同上，**不多一个判据** |
| 服务类型 | `remoteMessaging` + `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_REMOTE_MESSAGING` | §1.2 门2a；**不选 `dataSync`**（门2b 平台劝退 + 门3 的 6h 额度） |
| 常驻通知 | 一条低重要级、"正在跑 · <会话标题>"、静音；只在回合期间存在 | 门5：声音/震动归用户；低重要级 = 不长响 |
| 心跳 | **照常 60 s**（删掉 `if (!_foreground)` 那一行），前后台同一套 | 三问①：删掉这条规则，平台/协议已给出答案（半开判 2 个周期） |
| 通知权限被拒 | **不启动服务**，设置项显示"系统已关闭通知"并给跳转 | 服务的唯一可观察产出是通知；保活却看不见 = 白耗电（这条是**新规则**，必须进 `docs/`） |
| ROM 杀进程 | 不预设；量完再决定要不要在设置页提示"自启动 / 电池优化"（§8） | 不许猜 |
| 撤销口径 | 条目的 `itemId` 离开待处理集合 ⇒ `cancel`；回前台**且**看着那个会话也撤 | 与 DSH 的"在主视图里就不算未读"同一条（§1.4） |

**通知上的"直接答"是不是原生能力** —— 是，但**只是同一个入口的第二个触发面**：

| 授权三条硬规则 | 通知上怎么满足 |
|---|---|
| 未授权绝不生效 | 按钮**只在**该 `itemId` 仍在待处理集合时出现；点击只发 `interaction.respond`；回 `interaction/not-pending` ⇒ 撤通知、**不写成功回执**（App 侧已有失败分类，见 `implemented/2026-10-23-in-flight-interaction-is-host-held.md`） |
| 勾选态不跨次残留 | 通知 Action **没有勾选态**（一次性 `PendingIntent`）。**提问不做通知内答题**，正是为了不引入"跨次残留"与多选态 |
| "允许一次" ≠ 永久授权 | 只提供 `selected: ['allowed-once']`（DSH 的 outcome 值，`user-approval/src/types.ts:32`；契约 §5.7 那行）一个正解，**不提供"总是允许"**；拒绝 = 空 `selected` 且无 `custom` |

**答复需要后台上下文**：审批的两个按钮走 `PendingIntent` → 一个**原生 `BroadcastReceiver`** → MethodChannel → Dart →
`interaction.respond`。它要求引擎活着 —— 而通知**只在前台服务活着时存在**，所以两者天然同生共死，不需要新的一致性规则。
（代价：要写原生 Kotlin；`verify-platform-boundary.mjs` 的 `branch-whitelist` 允许 MethodChannel 出现在
`lib/platform/` 与 `packages/**`，所以放 `lib/platform/notify_android.dart` 不破门禁。）

**去重与"我看过了"**：通知 id 从 `itemId` 派生（`i:<approvalId>` / `t:<callId>` 已经在手机上唯一），
**不新开一张"已提醒"表** —— 待处理集合本身就是真值（§4 撤销口径）。这是"单一真值"在此处的落点。

## 5. 契约与文档影响（精确到位置）

| 位置 | 现状 | 改成 |
|---|---|---|
| §13 表下 "- 安卓**不以前台服务保活作为通知保证**……" 与 "- **三端都不做后台长连接**" | 一句否掉全部 | "三端**默认**不做后台长连接。**安卓例外**：有跑动中的回合且用户开启时，用前台服务（`remoteMessaging`，无时限）保住**同一条**连接，回合收口即停；通知权限被拒则不启动。iOS / 鸿蒙仍不做。" |
| §2.2 `backoff` 行 | "**只在 App 前台重连**;切后台主动断开并停表" | "前台照常退避重连；后台在**前台服务存活期间**用同一张退避表重连，服务停止即断开。" |
| §9 心跳行 | "**仅在前台**且连接空闲时每 60 s" | "连接空闲时每 60 s（前后台同一套）。" |
| §9 批量合并行 | "前台用小间隔,**后台不推**(后台本来就没连接)" | "前台用小间隔；后台连接存活期间沿用同一间隔（**不新造第二档**）。" |
| §15 | — | 新增四条：① 通知权限被拒 ⇒ 通知不可见、服务不启动；② ROM 杀进程不可控（量测结果附上）；③ **定时任务 / 工作流在无 `running` 时起的轮次不会被通知**；④ Local Network Permission 未来可能影响直连拓扑（§1.2 门7） |
| §5.7 | — | **不加方法**。通知完全复用 `interaction.respond` |
| `docs/subsystems/` | 无通知篇 | 新增 `notifications.md`（渠道 id、触发源、撤销口径、"权限被拒不启动"这条规则的唯一表达处） |
| `docs/subsystems/app-platform-boundaries.md` §1 | 画了 `packages/notify` 等五个包 | 与磁盘对齐：现在是 `lib/platform/` 一层；能力包目录要么建、要么改图（**不许图上有、盘上没有**） |

## 6. 改动面清单（按提交切，每件一个提交 + 一篇笔记）

| # | 件 | 契约 | 代码 | 门禁 / 测试 |
|---|---|---|---|---|
| 1 | 通知端口 + 安卓实现 + 假实现 | — | `lib/platform/notify.dart`（端口：`show` / `cancel` / `status`）+ `notify_android.dart` + `notify_memory.dart`（假实现带 `kDebugMode` 守卫 —— 注意 `fallback-not-in-release` 只扫 `app/lib/platform/registry.dart`（`app/tools/verify-platform-boundary.mjs:119`），**这个文件目前不存在**，装配点仍在 `main.dart`） | `verify-platform-boundary`（新增文件数）；Dart 单测用假实现 |
| 2 | 前台服务 + 保活 | §2.2 / §9 | `lib/platform/foreground_service.dart`；`AppModel` 用 `_runningSids` 驱动；原生 `DshForegroundService.kt` + manifest；**删**死码：`connector/src/transport/keepalive.ts:37,82`、`batch.ts:36,78`（零生产调用点，只有 `tests/transport.test.ts:71,94,96`）与手机侧 `app/lib/core/keepalive.dart:93`、`sync_client_impl.dart:1155` | connector 项数会**降**（断言随行为删除，须在笔记里写明不是放宽） |
| 3 | 三条触发源 → 通知 | §13 / §9 / §15 | 纯 Dart：订阅 `sessionStatus` + 待处理集合 → 端口 | widget/单测：边沿产生一条、离开集合撤一条 |
| 4 | 通知上的审批按钮 | — | 原生 `BroadcastReceiver` + MethodChannel → `interaction.respond` | 三条硬规则各一条断言（未授权不生效 / 无勾选残留 / 只有 allowed-once） |
| 5 | 抽屉四态点（短板 #1） | — | `AppModel` 的 `completionUnread` 派生（**不落盘**）+ `session_drawer.dart` 行首点（`Rows.tsx:344-398` 的优先级与 `StateDot` 形态） | 单测：边沿置位、"看着它"清位、基线不置位 |
| 6 | 设置页"未读到"统一（短板 #2） | — | `settings_page.dart:248-249` | widget：未读到时不出开关态、显示"未读到" |
| 7 | `@` 占位符（短板 #3） | — | `dsh_composer.dart:130,137` **删 `@ 文件或对话` 半句** | widget 断言文案 |
| 8 | `/` 候选菜单（短板 #4） | §5.7 `repo.info` 行（若要单源） | 输入框触发 + 候选 = 白名单两条 | 契约与 `MOBILE_COMMANDS` 同源断言 |
| 9 | 用量页折叠（短板 #5 第一档） | — | `usage_page.dart:116` | widget |

## 7. 五条界面短板的口径（改哪里 / 判据 / 成本）

1. **抽屉会话行运行中 / 完成态** —— 改 `session_drawer.dart` 行首点（现在是"当前会话"蓝点，`:733-741`），
   换成 DSH 的四态优先级（§1.4）。**判据**：`pendingInteraction` 存在时画 `warning` 而不是 `ongoing`；
   `running` 变 `false` 且**不在前台看着它**才画 `done`；基线（首次 `session.list`）不置 `done`。
   **成本**：`AppModel` 一个派生集合（`_runningSids` 已有，无需落盘）+ 行 UI 换一处 + 3 条单测。**小，收益最直观。**
2. **设置页"上传 Session Log"不许画成"关"** —— `settings_page.dart:244-253`：`onChanged` 在未读到时
   已经是 `null`（开关禁用），但 `value` 仍被算成 `false`（`_SettingSwitchRow:546-549` 照画一个关着的开关）。
   改成未读到时**不出开关**、副标题写"未读到"（与旁边三项 `?? '未读到'` 同口径）。**成本**：1 处 UI + 1 条 widget。
3. **`@`** —— **更正过一次成本口径**：初版写"`@` 不是 1 行的事、重"，说过头了。**证据**：DSH 的 `@` 在线上就是
   **文本 token** —— 文件是 `@path` / `@"带空格的路径"`（`/packages/context/file-reference/src/grammar.ts`，
   反解语法见 `ui-reference/src/client/user-text-rules.ts:22`），会话是 `@[label](<不透明 URI>)`
   （`/packages/context/session-reference/src/uri.ts:48-51`）；而**候选里本来就带着这个字符串**
   （`ui-reference/src/client/index.ts:282,298` —— *"every candidate carries the canonical mention a host inserts"*）。
   所以手机侧 = **1 个只读窄口**（文件 `remote.fileReferences.list`、会话 `remote.sessionReferenceResolver.candidates`，
   出处 `index.ts:90-95`）× 一个选择面板 × 把 `mention` **原样**插进输入框（不自己拼 URI）。
   **成本：各半天，不是"重"**；本轮仍不做，但理由从"重"改成"要加两个只读方法，排在本轮之后"。
   占位符里的 `@ 文件或对话` 在此之前**要么删掉、要么就实现**（现在的状态是假入口）。
4. **`/` 候选菜单** —— 候选只能来自 `MOBILE_COMMANDS`（`connector/src/handlers.ts:77`，只有 `/goal` `/plan`）。
   **风险**：手机手抄这份名单 = 第二真值（连接器加第三条时手机永远看不到）。
   建议单源：`repo.info` 报 `caps.commands`（`handlers.ts:12-13` 的注释已经为"报表的键而不是手抄清单"立过规矩）。
   **成本**：菜单纯 UI（小）+ `repo.info` 一行（契约 §5.7 一行）。
5. **用量页** —— 折叠（纯 UI，`:116` 现在把所有 section 直铺进 `ListView`）→ 日期筛选（**要 `usage.summary` 加参数**
   ：`handlers.ts:731` 是 `async () =>`，零参数；+ 契约 §5.7 一行）→ 矩阵/明细（**先定聚合口径**，不做）。
   提醒照旧：**DSH 桌面没有用量页**（`packages/client` 里没有 `ui-usage`），这一页是本仓自己的面，形态要写进 `docs/`。

## 8. 真机量法（MIUI 那一节只能量，不许猜）

**目的**：`remoteMessaging` 前台服务在这台 MIUI 上锁屏后能不能活过 10 分钟；活着时连接与通知是否都在。

**做法（一次装包 + 一次长跑，1 次模型请求）**

1. `flutter build apk --debug` + `adb install -r`（**不要** `flutter install`，它会先卸载、配对凭据全没）；
2. 授予通知权限：`adb shell pm grant com.example.dsh_mobile android.permission.POST_NOTIFICATIONS`
   （先看 `cmd appops get` 的 `POST_NOTIFICATION` 是否变 `allow` —— 这是"系统侧证据先于接线"）；
3. 让模型跑一条 `Start-Sleep -Seconds 600`（纯 ASCII，空格写 `%s`），**立刻**按 Home 让 App 进后台；
4. 锁屏：`adb shell input keyevent 26`；在第 0 / 2 / 5 / 10 分钟各采一次：
   - `adb shell dumpsys activity services com.example.dsh_mobile`（`ServiceRecord` 在不在、`isForeground=true`、`foregroundId`、`startRequested`）
   - `adb shell dumpsys notification --noredact`（`dsh_running` 渠道在不在、常驻通知在不在）
   - 手机侧连接：`adb shell dumpsys netstat | findstr 8790` / 电脑侧 `netstat -ano | Select-String ':8790'`
   - 电脑侧真值：`.dsh/storages/dsh_mobile_core.json` 的 `LastWriteTime`、中转 `devices[].online`
5. **服务里打点**：原生 Kotlin 用 `Log.i("DshFgs", …)` 记 `onCreate / startForeground / onTimeout / onDestroy`，
   采 `adb logcat -s DshFgs`。**这一条同时补上一个已知缺口**：此前 App 侧证据只有现象，
   因为 Flutter 的 `flutter` 标签 0 行（`memory.md` 已记）；**原生标签是能出来的**。
6. **反面对照**（区分"没命中"与"没实现"）：同一台机器、同一个会话，**不开**服务（现状）→ 锁屏 2 分钟后连接必断。
   两组都记，才说明"保活真的起了作用"，而不是"本来就活着"。
7. 记录口径：ROM 版本 `OS3.0.306.0.WNKCNXM`、电池优化是否白名单（`dumpsys deviceidle whitelist` 里有没有本包）、
   自启动是否开（MIUI 的 `com.miui.securitycenter` 里查，**只能人工看一眼**，没有可读的 API）、Mi Push 是否开。

## 9. 需要拍板

1. **通知走 A 收窄版**（跑动中保活 + 通知）吗？—— 会改契约 §13 / §2.2 / §9 三处散文，**协议零改动**。
2. **同批做 C 的部分**（抽屉四态点）吗？—— 0 真机、0 契约，且它是通知之外唯一"看得见"的收益。
3. **`@`** 去掉占位符（建议）还是先做 `@会话`（要新窄口）？
4. **`/` 候选**配不配 `repo.info.caps.commands`（否则手机是第二真值）？
5. **用量页**本轮只做折叠？
