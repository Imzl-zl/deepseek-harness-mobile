# 通知与后台保活

App 退到后台之后还能不能提醒、以及靠什么保住那条连接。

## 1. 三条判据（缺一不可）

前台服务只在**同时**满足下面三条时起（`AppModel._syncKeepAlive`）：

| 判据 | 来源 |
|---|---|
| App 在后台 | `AppStateReporter` 的 `isForeground`（只有 `resumed` 算前台） |
| **系统给了通知权限** | 原生 `status.granted`（API 33+ 的 `POST_NOTIFICATIONS`） |
| 连接在服务态 | `client.state == serving` |

回前台、掉出服务态、或权限被收回 ⇒ 停服务。

**为什么没权限就不起**：平台明文 —— 拒绝 `POST_NOTIFICATIONS` 时前台服务的通知**进不了
通知抽屉**（只在 Task Manager 里可见）。那条服务唯一可观察的产出就没了，起了只是白耗电。

## 2. 前台服务的类型

| 类型 | 时限 | 结论 |
|---|---|---|
| `dataSync` | 24 小时内累计 **6 小时**，到期调 `onTimeout`，再起抛 `ForegroundServiceStartNotAllowedException`；且属性文档写 targetSdk≥34 *"this type should NOT be used"* | **不用** |
| `specialUse` | 无时限 | 要 `<property>` 子类型 + Play 审核；语义不诚实 —— 备选 |
| **`remoteMessaging`** | **无时限** | **用这个**：平台描述是"设备间消息接力、切换设备时保持消息任务的连续性" |

需要 `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_REMOTE_MESSAGING` 两条权限，manifest 里
`android:foregroundServiceType="remoteMessaging"` 必须与 `startForeground` 传的常量一致。

## 3. 三类提醒（触发源全是既有语义）

| 通知 | 触发源 | 能不能直接答 |
|---|---|---|
| 等你审批 | 本地条目里的 `ApprovalItem` 且 `!decided` | **能**：「允许一次」/「拒绝」两个按钮 |
| 有人在问 | `ask_user_question` 的 `tool/call` 且 `ToolCallStatus.running` | **不能**（点开去答） |
| 跑完了 | `completionUnread`（`running` 的 `true→false` 边沿） | — |

**没有第四份状态机**：三类都是既有事实的投影；"已提醒过哪几条"也只记在内存
（`_activeNotices`，杀 App 即丢，与"完成绿点"同一条理由）。

**前台且正看着那个会话 ⇒ 不提醒**：结果就在眼前（与 DSH 的"在主视图里就不算未读"同一条）。

## 4. 答复与授权

- 按钮走 `PendingIntent.getBroadcast` → `DshActionReceiver` → `DshNotificationBridge` → Dart →
  **既有唯一出口** `interaction.respond`（键是 `itemId`，审批 `i:<approvalId>`）。
- 「允许一次」= `selected: ['allowed-once']`（DSH 的 outcome 值）；「拒绝」= 空 `selected` 且无 `custom`。
  **没有「总是允许」** —— 通知按不出永久授权。
- 按钮只在那个 `itemId` **仍在待处理集合里**时存在；答复失败（`interaction/not-pending` 等）
  ⇒ 撤掉通知并留声，**不回写成功回执**。

## 5. 撤销口径

- 那个 `itemId` 离开待处理集合（有人答了 / `approval/decided` 到）⇒ `cancel`。
- 切到那个会话、或 App 回前台且看着它 ⇒ `cancel`。
- **不做"已提醒"落盘**：撤销靠派生，重启后重新派生的那批自然重贴（这正是要的）。

## 6. 通道协议（`dsh/notifications`）

| 方法 | 方向 | 说明 |
|---|---|---|
| `status` | Dart→原生 | `{granted, keepAlive}` |
| `requestPermission` | Dart→原生 | API 33+ 运行时请求，回**请求之后**的真实状态 |
| `startKeepAlive` / `stopKeepAlive` | Dart→原生 | 起停 `DshForegroundService` |
| `show` / `cancel` / `cancelAll` | Dart→原生 | 贴 / 撤通知（`show` 带 `itemId` 时画两个按钮） |
| `openChannelSettings` | Dart→原生 | 跳系统渠道设置（`ACTION_CHANNEL_NOTIFICATION_SETTINGS`） |
| `approval` | 原生→Dart | `{itemId, outcome}` |

## 7. 渠道

两个渠道，都在 `DshNotifications.ensureChannels` 里创建（幂等）：

- `dsh_running`（IMPORTANCE_LOW、静音、不可滑掉）—— 前台服务的常驻通知；
- `dsh_attention`（IMPORTANCE_DEFAULT）—— 三类提醒。

**声音 / 震动 / 重要级归系统**：渠道一经创建，App 改不了它们（平台明文）。所以 App 设置里
**没有**"震动开关"，只有一行「通知与后台保活」：说"系统给了没"，点它要权限或跳系统渠道设置。

## 8. 已知边界

见契约 §15（后台保活是尽力而为 / 定时任务起跑的轮次没有通知 / 未订阅会话的审批不提醒 /
提问不做通知内答题）。另：**用户从最近任务里划掉 = 结束** —— 那时 Activity 被 finish、
Flutter 引擎随之销毁，Dart 侧的连接与服务一起没了（不做缓存引擎，这正是"手动杀了才没"）。

## 9. 验证

- `cd app && flutter test test/notice_test.dart` —— 8 项：保活三条判据、审批/完成两类提醒、
  "看着它就不提醒"、"decided 就撤"、两个按钮的载荷（`allowed-once` / 空 `selected`）。
- 真机（原生部分进不了 `flutter test`）：装包 → 授予通知权限 → 发一句长跑 → 按 Home →
  锁屏 10 分钟，按 `dumpsys activity services` / `dumpsys notification` / 服务里 `Log.i("DshFgs", …)`
  取证据；反面对照是"不起服务"那一次（锁屏 2 分钟后连接必断）。
