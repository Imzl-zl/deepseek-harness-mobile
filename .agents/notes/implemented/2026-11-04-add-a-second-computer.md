# 一台手机配多台电脑：槽位早就有了，缺的是"只加不删"的入口

- 日期：2026-11-04
- 触发：用户问「不是说要能切换着看多台电脑端吗，不能实现吗」
- 状态：implemented（切换与添加已可用；**同时在线**仍未做，见文末）

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

用户看到的"不能切多台"，根因不在切换，在添加。

## 决定

新增一条与「重新配对」并列的路：

- `ChatPage.onAddHost` → `MainScreenState._addHost()` → `_enterPairing('')`；
- 它**不清凭据**（`_reassembleUnpaired()` 只拆内存里的客户端，落盘的槽原样保留），
  配对成功后 `pairingStore.save()` 写进**新**槽，`active` 指向新的那台；
- 连接面板加一行「添加电脑」（`onAddHost` 非空就画），副标题写明
  「扫另一台的配对码；当前这台不会被清掉」——这是它与「重新配对」唯一的区别，
  而"会不会清掉我这台"正是用户唯一会担心的点。

两条路的语义于是收敛成一句话：**「重新配对」是同一台电脑换身份/重来，「添加电脑」是再加一台**。

## 顺带：面板收了五成

同一天用户还说「这里的选项太多了，实际上其实是就几个有用的」。连接面板从七行收到四行：

```
当前连接 · <走的哪条>
切换电脑        （有第二台时才出现）
添加电脑
重新连接
取消
```

撤掉的五行与去处：

| 撤掉 | 去处 |
|---|---|
| 重新配对（换一台电脑） | 空态那条出路仍在（`chat_empty_state_test.dart:124` 钉着） |
| 换个连接方式 | 设置页顶部块（同一个 `connectionSummary`） |
| 手动填写电脑地址 | 设置页「添加端点」 |
| 打开侧面板 | 右滑 / 顶栏本来就有 |
| 断开连接 | 用户明确说不需要；`AppModel.disconnectLink()` 仍在，只是不给这一屏 |

函数签名里的 `onRePair` / `onDisconnect` / `onOpenSide` / `onPickEndpoint` / `onManualEndpoint`
暂时保留（调用方与测试还在传），等设置页的入口落地后一并删。

## 代价 / 没做的

- **不能同时看多台**：`AppModel` 只持有一个 `SyncClient`（`main.dart` 的 `createSyncClient`），
  一条连接一套修订号 / 去重表 / outbox。要"同时在线"就得让每个 host 各跑一套，
  那是 `core` 层的架构改造，不是 UI 开关。本次**只做"切得过去"**。
- 「切换电脑」列表目前只显示名称 / 短码 / 当前|已配对，没有缓存状态（上次连接时间、
  会话数、最近一条摘要）—— 那是下一步，判据要落在 `PairingStore` 的 `hosts()` 返回值上。

## 验证

- `app/test/connection_actions_sheet_test.dart`：改成钉新形状 —— 「添加电脑」pop 并回调一次、
  「重新配对 / 打开侧面板 / 断开连接」**不在这屏**、无锚点时仍是底部 sheet。
- 真机：配第一台 → 面板只有「添加电脑」；再扫第二台 → 出现「切换电脑」，
  来回切两台，凭据与界面桶（`host.<hostId>.*`）各归各的。
