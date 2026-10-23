# Agent Note: 后台保活（`remoteMessaging` 前台服务）+ 三类通知

Status: implemented（**原生部分未过真机** —— 见文末"还没验的那一半"）

## Problem

切后台主动断连（`sync_client_impl.dart` 的 `setAppState`：先报 `background` 再 `_disconnect()`），
于是**后台收不到任何事件 ⇒ 没有东西可以变成通知**。契约 §13 当时把这条写成"三端都不做后台长连接"。

## Decision

### 1. 后台连接：安卓开一个"常驻"的前台服务（改 §13/§2.2/§9 三处散文，**协议零改动**）

- **类型 `remoteMessaging`**（不是 `dataSync`）：平台原文 *"Transfer text messages from one device
  to another. Assists with continuity of a user's messaging tasks when they switch devices."*，
  **无时限**；`dataSync` 有 24 小时内 6 小时的额度、且属性文档直接写 targetSdk≥34 *"should NOT be used"*。
  出处与三选一的对照见 `docs/subsystems/notifications.md` §2。
- **起停三条判据**：App 在后台 + **系统给了通知权限** + 连接在服务态。回前台 / 掉出服务态即停。
  "没权限就不起服务"是**新规则**（服务唯一可观察的产出是通知，看不见只是白耗电），写进 docs。
- **心跳不再分前后台**：两侧 `tick()` 的半开判定本来就在前台判断之前，删掉 `if (!foreground)`
  那一条就够 —— 后台停心跳只会让一条健康连接在 120 s 后被自己判死。
- **帧与协议一个字没改**：`sync.hello.app = 'background'`、`presence.app` 早就在契约里
  （§5.4 / §3 帧表），后台连接是"写在协议里、被 §13 禁止使用"的分支。

### 2. 三类通知，触发源全是既有语义

| 通知 | 触发源 | 直接答 |
|---|---|---|
| 等你审批 | 本地 `ApprovalItem` 且 `!decided` | **能**（「允许一次」/「拒绝」） |
| 有人在问 | `ask_user_question` 的 `tool/call` 且 `status == running` | 不能（点开去答） |
| 跑完了 | `completionUnread`（`running` 的 true→false 边沿） | — |

- 通知上的按钮 → `PendingIntent.getBroadcast` → `DshActionReceiver` → `DshNotificationBridge` →
  Dart → **既有唯一出口** `interaction.respond`。**没有第二条答复路径、没有新方法**。
- **"已提醒过哪几条"不落盘**（`_activeNotices` 内存差集）—— 与"完成绿点"同一条理由。
- **不造震动开关**：渠道一经创建，声音/震动/重要级归系统（平台明文）。设置里只有一行
  「通知与后台保活」：说"系统给了没"，点它要权限 / 跳系统渠道设置。

## Alternatives considered

1. **`dataSync` 类型** —— 最强理由：它的描述（"上传下载、网络传输"）最接近"保持一条网络连接"，
   而且是最早被广泛使用的类型。
   被否：**24 小时内累计 6 小时**的硬额度（超了抛 `ForegroundServiceStartNotAllowedException`），
   而"常驻"必然撞上它；平台还在属性文档里劝退 targetSdk≥34 的应用。选它等于把"常驻"做成"每天能用 6 小时"。
2. **`specialUse`** —— 最强理由：无时限、语义上是"其它类型都不合适时的兜底"，用它不必勉强解释
   `remoteMessaging` 的"消息接力"。
   被否：要 `<property>` 子类型声明，且**Play 的审核要求**（我们侧载不走 Play，所以那条不成立）
   ——但语义上更难自证；`remoteMessaging` 至少能对着平台原文说清"两台自己的设备之间接力会话"。
   留作备选。
3. **`FlutterEngineCache` 把引擎活到"任务被划掉"之后** —— 最强理由：那样连"手动杀了"也能继续提醒，
   最接近 IM 的观感。
   被否：代价是把 App 启动形态改掉（引擎搬到 `Application`），而用户要的语义正是
   **"手动杀了才没"**；多活的这一段还会带来"通知挂着但 App 不在"的困惑。
4. **只在"有跑动中的回合"时保活（turn-scoped）** —— 最强理由：常驻通知不是永久噪音，耗电更省。
   被否：它**多一条我们自己的生命周期规则**（何时起/何时停两套判据），而覆盖的触发面**完全一样**
   （审批与提问都发生在 `running` 为真的期间）。少一条规则、少一处漂移。
5. **通知内给提问做答题按钮** —— 最强理由：那才是"从通知直接处理"的完整体验。
   被否：`AskUserQuestionAnswer` 是逐问的 `{id, selected[], custom?}`，多选与"其它"用按钮表达不了，
   硬做就是发明一套与宿主不同的答题面（契约 §6.3.1 明写"答案批次原样转发"）。

## Consequences

- **收益**：App 在后台时，审批能**在通知栏里直接答完**（「允许一次」= DSH 的 `allowed-once`，
  按不出永久授权）；跑完与提问也有提醒。
- **代价（如实记）**：一条**不可滑掉**的常驻通知（只在后台 + 有权限 + 在服务态时存在）。
- **代价**：**后台保活是尽力而为** —— 划掉任务 = Activity finish = 引擎销毁 = 连接与通知一起没；
  国产 ROM 的省电策略也可能杀掉它（真机待量）。
- **代价**：**没订阅过的会话**的审批 / 提问不会提醒（待处理集合来自本地条目，与抽屉行上
  "N 个待处理"同一个边界）；**定时任务 / 工作流**在没人操作时起的轮次也没有通知（写进 §15）。
- **删掉的东西**：电脑侧 `Keepalive.setForeground` / `Batch.setForeground` 的语义随之作废
  （它们本来就只有测试在调）。**本轮没删**（不在这一件的判据里）—— 见下"还没做的那一半"。

## 判据

- flutter **1164 → 1172**（`app/test/notice_test.dart` 8 条）：保活三条判据（含"没权限就不起"）；
  审批 / 完成两类提醒；"看着它就不提醒"；`decided` 就撤；两个按钮的载荷
  （`allowed-once` / 空 `selected` 且无 `custom`）；幂等键 = `itemId`。
- boundary **363 → 369**（+4 个 Dart 文件：`core/notify` / `platform/notify_android|memory|factory`）。
- `dart analyze --fatal-infos` 0、`dart format` 0、connector **620** 持平。

## 还没验的那一半（必须说清）

**原生部分进不了 `flutter test`**：`DshForegroundService` / `DshNotifications` /
`DshActionReceiver` / manifest 的类型与权限，只能装包到真机才作数。要验的是：

1. 授予通知权限后，按 Home 退到后台是否真的起了服务（`dumpsys activity services` 里
   `isForeground=true`、类型 `remoteMessaging`）；
2. 锁屏 10 分钟后服务与连接是否还在（`dumpsys notification` + 电脑侧是否还在收帧）；
3. 通知上的「允许一次」按下去，电脑侧的 `approval/decided` 是否带 `allowed-once`
   （判据同 `implemented/2026-10-24-terminal-identity-from-pc.md` 那套"谁答的"）。
4. **反面对照**：不起服务（没权限）时锁屏 2 分钟连接必断 —— 用来证明"判据能区分没命中与没实现"。

还没做的另一半（下一件）：删掉电脑侧那两个已经作废的 `setForeground`（含其测试），
并在 `docs/subsystems/notifications.md` §2 补上 MIUI 的量测结论。

## 代码入口回指

`app/lib/core/notify.dart`（端口与 `noticeIdOf`）、`app/lib/platform/notify_android.dart` /
`notify_memory.dart` / `notify_factory.dart`、`app/lib/data/app_model.dart`（`_syncNotices` /
`_syncKeepAlive` / `_answerFromNotification`）、`app/android/app/src/main/kotlin/.../Dsh*`、
`docs/subsystems/notifications.md`。
