# 一台手机配多台电脑：补"只加不删"的入口，并让取消回得来

- 日期：2026-11-04
- 触发：用户问「不是说要能切换着看多台电脑端吗，不能实现吗」
- 状态：implemented（**真机待验**；同时在线仍未做，见文末）

## 现状（改动之前）

多机的地基是齐的：

- `PairingStore` 按**电脑公钥**（`pcSignPubHex`）分槽：`dsh.pairing.<hostId>.<field>`
  加一条 `dsh.pairing.active` 指向当前那台；
- `pairingStore.save()` **只写自己那台**，不碰别的槽；
- `HostSwitchSeam`（`otherHostCount` / `onSwitch` / `onSwitchBack`）已经接在连接面板上，
  `> 0` 时才画「切换电脑」那一行。

缺的是**入口**：进配对页只有一条路 —— 连接面板的「重新配对」，而它走
`ConnectionRecovery.repair()`，即 `clearCredentials()` → `openPairing()`，
**先清掉当前这台**再扫。于是扫完第二台，第一台的槽已经被清掉了，
`otherHostCount` 永远是 0，「切换电脑」永远不会出现。

## 决定

1. 连接面板加一行「添加电脑」（`onAddHost` 非空就画），副标题写明
   「扫另一台的配对码；当前这台不会被清掉」——这是它与「重新配对」唯一的区别，
   而"会不会清掉我这台"正是用户唯一会担心的点。
2. `_addHost` **不 clear**：`_reassembleUnpaired()` 只拆内存客户端，落盘的槽原样保留；
   配对成功后 `pairingStore.save()` 写进**新**槽，`active` 指向新的那台。
3. **取消要回得来**：`_addHost` 进配对页前记住 `_hostBeforeAdd`；`_closePairing`
   在 `_addingHost` 为真时走 `_switchTo(hostId)`（读槽 + 装配 + start），
   而不是只把 `_pairing = false`。没有这一步，用户取消后会停在"未配对"，
   只能重启 App —— 那不是取消，是把当前电脑弄丢了。
4. **同时撤掉「打开侧面板」行**：右滑与顶栏独立按钮已经能开，面板里再放一行纯重复；
   用户 2026-11-05 原话「我滑动都打开了啊」。撤的是重复入口，不是能力。

两条路的语义于是收敛成一句话：**「重新配对」是同一台电脑换身份/重来，「添加电脑」是再加一台**。

## 被否掉的

- **复用「重新配对」**：它先 `clear()`，扫第二台时第一台槽已经没了 —— 这正是原 bug。
- **顺手把「重新配对」「断开连接」等行从面板撤掉**：那是另一件事，且会碰到
  "任何界面状态下两步内能走到重新配对"的事故判据（2026-10-15 postmortem）。
  这次只加一行 + 撤掉与右滑重复的「打开侧面板」，不动重新配对/断开。
- **取消时自动切到"最近一台"**：手机自己换电脑，用户不知道它换了哪台；
  只回**进配对页之前那台**。
- **`_addHost` 里 `unawaited(_reassembleUnpaired())` 后立刻显示配对页**：
  用户马上点取消会和 `_reassembleUnpaired` 抢 `_app`，刚装回来的原电脑又被覆盖成
  未配对。改成等拆完再显示页面。

## 代价

- 进配对页时当前连接会断（`_reassembleUnpaired` 换掉客户端）；取消后重新 start
  原电脑，中间有一小段重连。这是"添加第二台"的固有代价，不是失败。
- **不能同时看多台**：`AppModel` 只持有一个 `SyncClient`，一条连接一套修订号 /
  去重表 / outbox。要"同时在线"就得让每个 host 各跑一套，那是 `core` 层改造。
  本次只做到**能加第二台 + 切得过去 + 取消回得来**。
- 「切换电脑」列表仍只有名称 / 短码 / 当前|已配对，没有缓存状态（上次连接时间、
  会话数、最近一条摘要）—— 下一步。

## 验证

- `app/test/connection_actions_sheet_test.dart`：新增「添加电脑」pop 并回调一次，
  副标题写明"当前这台不会被清掉"；既有「重新配对」用例仍绿（没有撤重新配对）。
- `app/test/add_host_cancel_invariant_test.dart`：源码结构断言 —— `_addHost` 记 host、
  `_closePairing` 走 `_switchTo`、`_onPaired` 清标记。理由见该文件头（私有 State
  + 全局 `pairingStore`，没有可注入 seam）。
- `dart analyze --fatal-infos lib test integration_test` → 0 issue。
- `flutter test --no-pub test/connection_actions_sheet_test.dart test/widget_test.dart`
  → **59 / 59** 全过。
- `flutter test --no-pub` → **1742 / 1742** 全过（main 既有 1739 + 新增 3）。
- 真机（Xiaomi 23113RKC6C / Android 16 / API 36）：
  - 已配对 → 面板出现「添加电脑」→ 进入配对页 → 返回 → 回到原会话，状态点绿、数据保留。
  - 面板不再有「打开侧面板」；右滑 / 顶栏独立按钮仍能开。
  - **未验**：真的扫第二台（当前只有一台电脑可用）；第二台扫码与来回切换待补。
