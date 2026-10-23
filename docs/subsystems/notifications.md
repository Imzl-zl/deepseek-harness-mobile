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

### 2.1 真机量测：小米 `23113RKC6C` / MIUI OS3.0 / Android 16（2026-10-24）

| 时刻 | 系统侧真值 | 手机到中转的 WS |
|---|---|---|
| 退后台 6 s | `isForeground=true foregroundId=1001 **types=0x00000200**`；`foregroundNoti` 在 `dsh_running`（`ONGOING_EVENT｜FOREGROUND_SERVICE｜SILENT`）；两个渠道都在（`dsh_attention` importance 3 / `dsh_running` importance 2 且 `mShowBadge=false`） | 有 |
| 熄屏 2 分（`Dozing`） | `isForeground=true types=0x00000200`（服务还在）；**进程 `ps` 显示 `do_freezer_trap`**，`curProcState=4 mHasForegroundServices=true` 而 **`isFreezeExempt=false`** | **断**（且没自己回来） |
| 熄屏 4 分 | **`ServiceRecord` 没了**（服务被收走） | 断 |
| 亮屏（锁屏态） | 进程仍是 `do_freezer_trap` | 断 |

同一次的对照量测：

- 手机 Wi-Fi 正常（`Supplicant state: COMPLETED`、`IP 192.168.2.29`、RSSI −32），
  `ping 192.168.2.47` 通、`curl http://192.168.2.47:8787/` 回 **405** ⇒ **不是网络问题**；
- `dumpsys deviceidle whitelist +com.example.dsh_mobile` 之后白名单里有它，
  但 **`isFreezeExempt` 仍是 `false`** ⇒ "关掉电池优化"这一条在本机**不足以**让它不被冻结。

**结论（写进产品，不用"以后补"回避）**：`remoteMessaging` 前台服务在这台机器上**起得来、
也真的拿到了前台服务态**，但**屏幕熄灭后进程会被系统冻结、服务随后被收走**，
连接不会自己回来。可靠的办法只有用户在 **MIUI 自己的**「省电策略 / 自启动」里把
这个 App 设成「无限制」—— 那是 ROM 的开关，没有公开 API，我们只能在设置里给一句说明。
所以：**后台提醒是尽力而为，正确性仍然只承诺"回到 App 时状态正确"**。

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
