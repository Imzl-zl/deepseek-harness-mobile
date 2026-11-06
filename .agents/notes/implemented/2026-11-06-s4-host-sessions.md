# S4：按电脑池化 `AppModel`（HostSessions）

- 日期：2026-11-06
- 触发：架构审查（`proposed/2026-11-06-branch-a-and-pr-audit.md` §四）的 S4；
  前置是 S3（`implemented/2026-11-06-s3-app-services.md`）。
- 状态：implemented

## Problem

`main.dart` 只有一个 `AppModel` 槽（`_app`）。"切换电脑"是**换槽 + 重新装配 + `dispose` 旧的**，
于是同一件事被拆成四份代价：

1. **切回去等于从零开始**：A 的 socket、握手、订阅、会话缓存全被丢掉，切回 A 要重新拨号 +
   重新订阅 + 从头拉数据。用户只是看了一眼 B，A 一直是好的。
2. **两台不能同时在线**：一台手机配多台电脑是正常用法（`docs/subsystems/app-channel-client.md`
   §6.4 的 N:M，两个方向都不设人为上限），而单槽的语义是"同一时刻只有一台活着"。
3. **通知 id 会撞**：`noticeIdOf('completed:<sid>')` / `approval:<itemId>` / `question:<itemId>`
   里只有 `sid` 与 `itemId`，而两者都由每台电脑独立分配 —— 两台撞名时撤掉 B 的那条会把 A 的
   一起撤掉（`cancel(id)` 只按 id 认人）。
4. **"移除"没有单独的语义**：`dispose` 既是"切走"也是"移除"，所以谁也不敢留旧的。

## Decision

1. **`data/host_sessions.dart` 的 `HostSessions`**：`hostId`（`pcSignPubHex`）→ `AppModel`。
   - `acquire(hostId, build:)`：**已有就原样返回**（`created: false`，不重启、不重读、不 dispose）；
     没有才装配。返回的 `created` 决定调用方要不要 `loadUiState()` 与 `start()`。
   - `replace(hostId, build:)`：装配新的顶替旧的，旧的 **dispose**（重新配对走这条 ——
     旧模型带的是旧 token，复用它等于拿作废的凭据去连）。
   - `forget(hostId)`：只 dispose 这一台（解绑 / 吊销 / 身份被拒 / 换凭据）。
   - `disposeAll()`：app 退出。
2. **"哪台可见"仍由 `_credentials` 决定**：`_app` 变成派生读
   （`_credentials == null ? _unpaired : _sessions.of(hostId)`）。切换 = 换 `_credentials`
   （一次 `setState`），池子里的模型一个都不动。没配对那个**不进池**（它不属于任何电脑）。
3. **装配仍是 `main.dart` 的事**：池子只记账，`build:` 由调用方给（它才知道用哪个实现）。
   每台的 `ScopedItemStore(inner, HostScope(hostId))` 照旧在 `_assemble` 里套 —— 分域跟装配走，
   池子不认识存储。
4. **通知 id 带电脑前缀**：`AppModel._noticeKeyOf(kind, id)` → `<hostId>|kind:id`；
   没有电脑身份时（未配对 / 单测）保持平铺形状。
5. **移除只撤自己那批**：`AppModel.dispose()` 从 `cancelAll()` 改成逐个
   `cancel(id)`（`_activeNotices` 里的那些）；`cancelAll()` + `stopKeepAlive()` 上移到
   `AppServices.dispose()`（app 退出）。
6. **前台服务改成 app 级汇总**（`AppServices.syncKeepAlive`）：一条服务、多台各报各的
   "要不要"，**只要还有一台要就留着**。原来每台各自读 `status().keepAlive` 再起停，
   两台时 A 要、B 不要就会把 A 的保活撤掉（`_keepAliveWants` 是映射，`want:false` 只撤
   自己那一格）。串行化用一条 `Future` 链：装配层一次广播会让几台同时进来，而
   "读 status → 起/停"中间有 `await`，交错会重复起服务。
7. **前后台态扇出到每一台**（`main.dart` 的 `_onAppLifecycle`）：`setAppForeground` +
   `reportToClient` 逐台。`AppStateReporter` 因此退回"只翻一个布尔值"（它不再认识客户端），
   `AppModel` 新增 `reportToClient(bool)`（把 `connectionForeground` 的判据与 `setAppState`
   放在一起）。只报可见那台的话，后台里其它台会一直以为自己在前台：心跳照走、长连接不退
   （违反契约 §2.2 / §13），它们的提醒判据也停在旧值上。
8. **"看着它就不提醒"按台算**（`AppModel.visibleOf`）：只有界面上那一台的当前会话算"在眼前"。
   不加这一条的话，A 上等着的审批会在用户看着 B 时**永远收不到提醒** —— 那是 S4 自己引入的
   回归（单槽时不存在）。
9. **`AppModel.dispose()` 补上 `client.close()`**：此前没人关传输层（`client.close` 在
   `app/lib` 里零调用点），于是"dispose 旧的"从来没能真的断开 socket。池化之后"移除这台"
   必须真的断开，所以这一步是前提。

## 被否掉的

- **给池子设台数上限 / 闲置超时回收**：宿主没有这种边界（电脑侧裁剪缓冲的判据是"这一轮在
  服务的设备"，与手机同时在线几台无关）。加起来就是新增边界，且"回收了谁"无从解释。
  内存随台数涨是用户自己配了几台的直接后果。
- **把"哪台可见"塞进 `AppModel`**（每个模型自己比较 hostId）：那就要在每次切换时**写**
  每一台（可变字段 + 记得同步），而它只是为了一个提醒判据 —— 用晚绑定的 `visibleOf`
  闭包读装配层的真值，忘了它也只会退化成"都可见"，不会读到错的内容。
- **保留 `setHostScope` 那类"切换时改模型字段"**：同 S2 的理由（隐式时序契约）。
- **每台一个 `AppStateReporter`**：`AppLifecycleState` 只从 `WidgetsBinding` 来，
  挂多个观察者会让"谁先看到"变成没人盯的顺序问题（`platform/app_state_reporter.dart` 的旧注释
  就是这个理由）。改成"一个观察者 + 装配层扇出"。
- **切换时把旧的 `stop()` 掉（保留连接但停心跳）**：宿主没有"暂停"这个概念，而
  "停心跳"在协议里就等于断连（§2.2）。要么活着要么断，没有中间态。

## 代价与已知边界

- **内存**：每台一份会话缓存（`items` 在内存里的那部分）。不设上限 —— 见上。
- **连接数**：同时在线 N 台 = N 条长连接（各自一条设备通道）。电脑侧本来就是"每设备一条"，
  没有新增语义；手机侧的电量代价是真实的，但那是"同时连几台"的直接后果。
- **`_app` 变成 getter**：`_credentials != null` 时它必须能在池子里取到（不变式由
  `acquire`/`replace` 先落池、再 `setState` 保证）。
- **重新配对会短暂地没有可见模型**：`replace` 是"装配新的（await）→ 顶替旧的"，装配期间旧的
  还在，所以没有空窗；`_reassembleUnpaired` 反过来是"先换没配对那个、再 forget 旧的"，
  也没有空窗。
- **真机双机验收未做**：见 `proposed/2026-11-06-branch-a-and-pr-audit.md` 与交接单的 P0-c
  （要两个 `DSH_HOME`、第二次扫码，本轮只有 adb、没有摄像头）。

## 验证

- `cd app && dart analyze --fatal-infos lib test`：No issues found。
- `cd app && flutter test`：1758 项全过（S3 后 1752 → +6：`host_sessions_test` 3 项、
  `notice_test` +2（两台同 id / 别台当前会话照旧提醒 / 移除只撤自己那批 共 +3，
  `app_state_reporter_test` 4→3 换了内容）、`assembly_invariants_test` +1）。
- **变异校验**（每条都实跑，见下表）：

  | 改坏什么 | 哪条断言变红 |
  |---|---|
  | `HostSessions.acquire` 总是重新装配 | 「切 A→B→A：A 不重启」 |
  | `_noticeKeyOf` 丢掉电脑前缀 | 「同一 `sid` / 同一 `itemId` 两台算出不同 id」（`Expected: length 2 / Actual: 1`）|
  | `_visible` 恒 true | 「池子里另一台的当前会话照样提醒」（`Expected: length 1 / Actual: {}`）|
  | `dispose` 改回 `cancelAll()` | 「移除一台只撤它贴的那批」（`Expected: true / Actual: false`）|
  | `syncKeepAlive(want:false)` 清空全部诉求 | 「每台各报各的」（`Expected: 1 / Actual: 0`，保活被撤）|

- `node app/tools/verify-platform-boundary.mjs`：756 项全过（扫描 174 个 Dart 文件；
  比基线 748 多 8 项 = 两个新文件 × 4 条扫文件的规则）。
- 协议三条：454 / 26 / 49 全过（本批没动 `protocol/`）。
