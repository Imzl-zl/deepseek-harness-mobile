# Agent Note: 下一轮提示词 —— 通知（前台/后台）与五条界面短板的调研 + 方案 + 落地

Status: proposed

> 用途：本轮的**唯一产出是提示词**（下面整段复制到新会话）。
> 上一轮（`proposed/2026-10-24-ui-gaps-and-notification-feasibility.md`）已经把五条界面问题与
> "通知为什么现在做不了"求证到 `file:line`，但**没有做后台通知的方案调研** —— 用户明确要求
> 「APP 后台也可以通知啊，前台肯定更可以，这个需要你好好调研」，且**尽量用原生能力**、
> 架构与源码要优雅、语义要清晰。这一轮就是那件事。

---

## 提示词（整段复制）

````text
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh）。中文回复。

本轮：**调研 + 定方案 + 落地通知能力**，顺带把五条界面短板排好队。先用少量真机/源码证据把方案钉死
（这一步 0 个真机回合），拿到我的准再动手写代码。

## 0 先读（别跳）
- `AGENTS.md` 的「常驻军规」（尤其**宿主语义优先**那三问）与 §6 的输入区/授权/密钥硬规则。
- `memory.md` 的「真机联调的成本纪律」与「前置事实」。
- `tools.md` 的 Pitfalls（真机五条坑 + `adb`/输入法/坐标那几条）。
- 三篇笔记：
  - `.agents/notes/proposed/2026-10-24-ui-gaps-and-notification-feasibility.md`（**本轮的问题清单与证据**）
  - `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`（审批/提问怎么到手机、谁先答谁赢）
  - `.agents/notes/implemented/2026-10-24-running-from-native-status.md`（运行态 = `status` 帧，会话完成可从
    `running: true → false` 的边沿得到）
- 契约 `docs/subsystems/remote-channel.md` 的 §2.2 / §5.4 / §13 / §15 与 §5.7 方法表；
  `docs/subsystems/app-platform-boundaries.md`（平台能力包与六条边界规则）。
- 现状事实（已核实，别再查一遍）：
  - 切后台**主动断连并停表**：`app/lib/core/sync_client_impl.dart:1152-1163`，注释原文
    「切后台主动断开并停表（§2.2）：三端都不做后台长连接（§13）」。
  - 审批/问答的答复只有一条出口：`interaction.respond`（键是 `itemId`：`i:<approvalId>` / `t:<callId>`）。
  - 白名单只有 `/goal` `/plan`（`connector/src/handlers.ts` 的 `MOBILE_COMMANDS`）；
    `@` 只有占位符文案、零实现（`app/lib/ui/dsh_composer.dart:130,137`）；
    抽屉会话行没有运行态（`app/lib/ui/session_drawer.dart:644` 只有抽屉头部的连接点）；
    `usage.summary` **零参数**（`connector/src/handlers.ts:731`）；DSH 桌面**没有用量页**。
  - 本仓**没有推送基础设施**（契约 §15：推送本期不做；方法表里没有 `push.configure`）。

## 1 报价（先报再动，拿到准再改代码）

预计 **2 个轮次**：

1. **调研 + 方案**（0 个真机回合、0 次模型请求）：把下面 §2 的每一条查成**带出处的事实**，
   写进一篇 `proposed/` 决策笔记（含被否方案与代价），并给出改动面清单（契约 / 代码 / 门禁 / 测试）。
2. **落地**（1 个轮次；真机 1–2 次，模型请求 0–1 次）：按我点头的方案实现 + 单测 + 边界门禁 + 真机验一次。

**开跑前把这份报价发我并拿到准**，再动 `dsh` / `adb`。

## 2 要调研的问题（每条都要给结论 + 出处 + 判据；查不到写「未找到」，禁止"通常如此"）

### A. 后台通知的真实可行性（这是本轮的核心，别用结论代替调研）
1. **Android 前台服务**：保一条 WebSocket 长连接要哪种 `foregroundServiceType`？各类型的**系统时限**
   与 **Android 14/15 的新限制**分别是什么（`dataSync` 的每日额度、`specialUse` 的审核要求、
   `connectedDevice` 的适用面）？出处要官方文档 + 本机 SDK 源码行号
   （`node app/tools/flutter-api.mjs <符号>` 只覆盖 Flutter；Android 侧读 SDK 平台源码/官方文档）。
2. **通知权限与渠道**：`POST_NOTIFICATIONS` 的运行时请求、渠道（`NotificationChannel`）的
   重要级/声音/震动由谁决定 —— **原生渠道本身就是"声音/震动"的唯一真值**，
   我们还要不要在 App 设置里再造一套"震动开关"？（三问①：删掉我们的开关，系统会不会已经给出答案？）
3. **国产 ROM（本机 MIUI/Android 16，机型 `23113RKC6C`）的额外门槛**：自启动白名单、电池优化、
   "锁屏后杀进程"的实际行为 —— **这条必须真机量，不许猜**（量法：前台服务起后锁屏 10 分钟，
   `adb shell dumpsys activity services` + 服务里打点的时间戳）。MIUI 上的**结论要写进文档**，
   因为它决定"后台通知到底靠不靠得住"。
4. **FCM / 厂商推送**：本仓是自建 DSH（无公网推送服务端），FCM 需要 Google 服务；
   国内 ROM 无 GMS 时的替代（小米推送/华为推送…）要接几家、各自 SDK 与审核成本。
   给一张"要接几家/谁维护/失败面"的表，然后**明确说要不要做**（默认：不做，理由要写清）。
5. **WorkManager 轮询**这条备选：最小间隔、能否在"没连接"的情况下拿到"有活干"这个事实
   （没有推送服务端时它只能盲轮询）⇒ 代价与收益写清，默认否。

### B. 三条候选方案（每条都要写：语义、代价、对契约的影响、被否理由）
- **A 前台服务常驻连接**（默认关、用户可见开关）：回到"后台长连接"，**会改契约 §13/§2.2**。
  必须写清：常驻通知长什么样（能不能做成"静默常驻"）、耗电实测、MIUI 白名单、权限被拒后怎么降级。
- **B 推送**（FCM/厂商）：要公网推送基础设施 + 逐家 SDK；**默认不做**，但要把"为什么不做"写成可复核的结论。
- **C 只做 App 内 + 前台通知**：不碰契约；覆盖"App 在前台、人在别的会话/页面"。
- **判据（选型用）**：哪一条是**补通道**（我们这条链路没有的东西），哪一条是**替宿主做决定**？
  通知的触发源**只能是既有语义**（`status` 帧的 running 边沿 / `approval/asked` / 提问事件），
  **不许新造"完成"这种状态机**。

### C. 通知里的"直接答"算不算原生能力
Android 通知支持 Action（甚至 Direct Reply）。要回答：
- 在通知上按「允许一次 / 拒绝」走哪条方法？（只能是既有的 `interaction.respond`，键是 `itemId`）
- **授权三条硬规则的约束**：未授权绝不生效、勾选态不跨次残留、"允许一次"≠永久授权 ——
  通知上的按钮怎么满足？（提示：审批的 `selected: 'allowed-once'` 与非空占位答案项）
- 通知里答复需要**后台上下文**（前台服务里发请求）⇒ 与 A/C 的选择耦合。
- 去重与"我看过了"的口径：通知撤销（`cancel`）与手机侧已答/桌面已答两条路怎么收口。

### D. 五条界面短板的落地口径（每条给"改哪里 + 判据 + 成本"）
1. 抽屉会话行加**运行中转圈 / 完成态 + 本地已读表**（数据已有：`status` 帧 + `session.list`）。
   要与 DSH 的 `activitySlot` 同语义（`app/lib/ui/dsh_app_bar.dart:184` 引的就是它）。
2. 设置页「上传 Session Log」未读到时**不许画成"关"**（`settings_page.dart:248-249`）；
   与旁边三项的"未读到"统一口径。
3. `@`：先做 `@会话`（数据已有）还是先把占位符里的 `@` 去掉？**给一个建议 + 理由**；
   `@文件` 需要的窄口（列目录/搜文件）与方法面影响一并列出，但**本轮不做**。
4. `/` 候选菜单：候选只能来自白名单（`/goal` `/plan`）；不做"通用命令面"（契约 §5.7 准入三条）。
5. 用量页：折叠（纯 UI）→ 日期筛选（要 `usage.summary` 加参数 + 契约一行）→ 矩阵/明细（要先定聚合口径）。
   提醒：**DSH 桌面没有用量页**，这一页是本仓自己的面，形态要设计决定、写进 `docs/`。

## 3 架构与实现纪律（用户原话：原生优先、源码要优雅、语义要清晰）
- **能力包边界**：通知属于平台能力。放进现有能力包结构（见 `docs/subsystems/app-platform-boundaries.md`），
  业务层只调用一个语义化的端口（如"这个会话有事件要提醒"），**不许在 `lib/ui` 里出现平台分支**
  （`verify-platform-boundary.mjs` 会拦；加依赖前先读 §4 的选型闸门）。
- **单一真值**：通知的"谁的/哪一条/是否已提醒"只能有一处表达；已读状态落盘走既有 `meta` 缝
  （`app_model.dart` 的 `kSendModeKey` 那一族），不新开一套存储。
- **不新增宿主没有的边界**：超时/重试/去重/优先级都要先问"DSH 有没有"；新加的必须写进 `docs/` 并在
  代码入口回指。
- **删干净**：改行为时顺手删掉死码与过期注释（本项目最常犯的是"规则删了、字段还在"）。
- **门禁**：`node protocol/verify-{fixtures,loopback,vectors}.mjs`、`verify-platform-boundary.mjs`、
  `cd connector && pnpm test`、`cd relay && pnpm test`、`cd app && flutter test`、
  `dart analyze --fatal-infos` / `dart format --set-exit-if-changed`。改断言要做**变异校验**。

## 4 交付物
- 一篇 `proposed/2026-10-2X-notifications-and-ui-gaps.md`：**事实（带出处）+ 三方案对照 + 被否理由 +
  代价 + 契约影响 + 改动面清单 + 真机量法**。这一篇是"等你点头"的评审物，先别写代码。
- 我点头后：每件一个提交（代码 + 决策笔记同批），契约该改的同步改（§2.2/§13/§15/§5.7 视方案而定），
  `memory.md` 的待办与已知缺口按结论更新。

## 5 纪律（本轮最容易犯的三条）
1. **不许把"我没查到"写成"这个不行"** —— 后台通知先给证据，再给结论。
2. **判据要能区分"没命中"与"没实现"**：先看系统侧证据（`dumpsys notification` / `dumpsys activity services`
   / 通知渠道列表），再怀疑 App 的接线。
3. **真机回合要算钱**：调研阶段 0 次模型请求；要用模型跑一轮就在报价里写清是哪一件、几次。
````

---

## 写这份提示词时核实过的事实

- 切后台主动断连：`app/lib/core/sync_client_impl.dart:1152-1163`（含注释「三端都不做后台长连接（§13）」）。
- 审批/问答的答复面：`interaction.respond`，键 `itemId`（契约 §5.7；`implemented/2026-10-24-interaction-identity-from-native-ids.md`）。
- 运行态：`status` 帧（`implemented/2026-10-24-running-from-native-status.md`）；`running` 的边沿是"完成"的唯一来源。
- 白名单：`connector/src/handlers.ts` 的 `MOBILE_COMMANDS = {goal, plan}`。
- `@` 零实现：`app/lib/ui/dsh_composer.dart:130,137` 只有占位符。
- 抽屉无运行态：`app/lib/ui/session_drawer.dart:644`。
- `usage.summary` 零参数：`connector/src/handlers.ts:731`；DSH 桌面无用量页（`packages/client` 里无 `ui-usage`）。
- 平台能力包与边界规则：`docs/subsystems/app-platform-boundaries.md` + `node app/tools/verify-platform-boundary.mjs`
  （360 项、6 条规则）。
- **未核实、留给下一轮查的**：Android 14/15 前台服务各类型的时长限制、`specialUse` 的审核要求、
  MIUI 的锁屏保活实测、FCM/厂商推送的接入面、通知 Direct Reply 的可用面。
  这些**没有一条**是我能在这里断言的 —— 提示词里因此写成"要查证 + 给判据"。
