# Agent Note: 「断开连接」只断链，配对凭据留在原处

Status: implemented

## Problem

连接操作 sheet 里那一行叫「**断开并清掉凭据**」：一个日常动作顺手把配对抹掉。
用户原话：

> 断开并清掉凭据 换成断开连接不好了……一般人谁会断开并清掉？误触怎么办？
> 你就是想在设置中不是可以清。

两点都成立：① 误触代价是重新扫码（配对凭据没了）；② "清凭据"本来就是
「重新配对（换一台电脑）」那件事，不需要第二个入口。

## Decision

1. 那一行改成「**断开连接**」：断链 + 停止自动重连，**凭据原样留着**。
   清凭据仍然只有「重新配对」一条路（它也回配对页，说明写在副标题里）。
2. 断开是**粘性意图**：`AppModel.userDisconnected` + 连接层 `_userDisconnected`。
   `start()`（启动 / 回前台 / 退避到点）在粘性期间**一律不动**；
   恢复只有「重新连接」（`AppModel.reconnectLink` → `SyncClient.reconnect()`）。
3. 连接摘要说实话：`userDisconnected` 时第一行是「已断开连接」、
   第二行「凭据还在，点「重新连接」随时回来」——不把它显示成"未连接/故障"。

准入门槛（可机械判定）：

1. 点「断开连接」→ `disconnect()` 被调一次、凭据层零调用、不回配对页。
2. 断开后调 `start()` → 连接层不再自己连回来。
3. 点「重新连接」→ 意图位清掉 + 真的拨一次。
4. 摘要里出现「已断开连接」而不是 `connectionLabel(closed)` 那种故障词。

## Alternatives considered

1. **保留"断开并清掉凭据"，只是加二次确认**
   - 最强的理由：一行两用，少一个入口，确认框能防误触。
   - 为何被否：它仍然把两件事（离线 / 解绑）绑在同一个按钮上，而解绑还有
     「重新配对」这个更说得清的入口。确认框不是"语义错误"的解药。
2. **断开就只是 `client.close()`（不留粘性意图）**
   - 最强的理由：一行代码，不用新状态。
   - 为何被否：`start()` 会被启动 / 回前台 / 退避到点自动调用，几秒后自己连回来 ——
     用户会看到"我明明断了它又连上了"，那正是"替用户猜场景"。
3. **把意图做成持久化（重启 App 仍保持断开）**
   - 最强的理由：最彻底，符合"选择权交给用户"。
   - 为何被否：重启 App 被普遍读成"重新开始"，自动连回去不违反直觉；
     真要长期不连，删掉那一台/那几条端点更直接。**先不做，等有人要**。

## Consequences

- 收益：误触只是掉线，不会再丢配对；"我要离线"这件事有了名分。
- 代价：多一个状态位（`AppModel.userDisconnected` + `SyncClient` 的 `LinkControl`）；
  能力接口而不是抽象方法，替身类不用改二十多处。
- 代价：断开后不会自动恢复，用户得想起来点「重新连接」（摘要里写明了）。

## 判据

- `app/test/disconnect_link_test.dart` 3 条（断开不碰凭据、自动 start 不复活、重新连接恢复）。
- flutter 1662 项全绿；`dart analyze --fatal-infos lib test` 0。

## 代码入口回指

- `app/lib/core/sync_client.dart` 的 `LinkControl`；`core/sync_client_impl.dart` 的
  `disconnect()` / `_userDisconnected` / `start()` 的守卫。
- `app/lib/data/app_model.dart` 的 `disconnectLink` / `reconnectLink` / `userDisconnected`。
- `app/lib/ui/connection_actions_sheet.dart` 的那一行；`model/chat_item.dart` 的
  `connectionSummary(userDisconnected:)`。
