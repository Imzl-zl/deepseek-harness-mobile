# Agent Note: 翻页失败必须有界面消费者 —— 可见 + 不自动重试

Status: implemented

## Problem

`AppModel.loadOlderHistory` 失败时把原因记进 `_historyFailure[sid]`，并暴露成
`AppModel.historyFailure`（`app_model.dart:4318`）。那条判据**只有单测读过**
（`test/history_paging_test.dart:79`），**没有任何界面消费者**。

后果有两个，第二个更糟：

1. **用户不知道发生了失败**。往上滑到顶、什么都没发生 ⇒ 读成"历史就这么多"。
2. **每次滑到顶都会再发一次注定失败的请求**。因为失败时 `hasOlderHistory`
   **故意**不变假（变了会让用户以为"历史到此为止"，那更误导 —— 那条判据本身是对的），
   而 `shouldLoadOlder` 只看 `hasMore`，于是滚动一次发一次，每次都失败、每次都
   `notifyListeners()`。

契约 §3.1 给 `session/window-missed` 的动作是"重新订阅 → 走快照"，代码注释里也写着
"只留声，让用户手动重进会话" —— 而那个"声"从来没到用户眼前。

## Decision

两半，各一条判据：

1. **可见**：`ui/history_failure_note.dart` 的 `HistoryFailureNote` —— 会话流最上端
   （`reverse` 下的最后一个 index）一格：标题「更早的历史没拿到」、原因原样、
   一句「重新进入这个会话可恢复」。
   **不放"重试"按钮**：重试 `loadOlderHistory` 必然再失败一次，那是假入口；
   契约规定的恢复动作是重进会话（`openSession`）。
2. **不自动重试**：`shouldLoadOlder` 增加 `failed` 参数
   （`ui/load_older_trigger.dart`），`failed == true` 时恒 `false`。
   调用点传 `app.historyFailure != null`。

顺带一处去重：列表与右侧跳转钮原来**各算一遍**同一个 `itemCount` 表达式，现在共用一个
`cellCount` 局部 —— 两处各算一遍迟早对不上，而失败格正好要多一格。

## 准入判据（三条文件）

| 文件 | 钉什么 |
|---|---|
| `test/load_older_trigger_test.dart` | `failed: true` 时恒不触发（含"不在顶上也一样"） |
| `test/history_failure_note_test.dart` | 文案原样（原因不吞）、写明恢复路径、**没有按钮** |
| 同上（第 3 条） | **接线**：真 `ChatPage` + 失败替身 ⇒ 屏幕上真的出现这一行 |

第三条是补上的，因为前两条通过了但**变异没红**：把 `ChatPage` 里
`historyFailure: app.historyFailure` 改成 `null` 之后，只测组件的两条照样绿 ——
**"组件画得对"不等于"它会被挂上去"**。补上接线用例后同一变异立刻红
（`Found 0 widgets with type "HistoryFailureNote"`）。

另一个变异：`shouldLoadOlder` 去掉 `if (failed) return false;` →
`load_older_trigger_test` 那条立刻红。

## Alternatives considered

1. **在行里放一个「重试」按钮**
   - 最强的理由：用户就在那一格，点一下最直接。
   - 为何被否：`window-missed` 的语义是"你要的那一页已经不在宿主的保留窗里了"，
     再翻一次**必然**失败。真正的动作是重新订阅（`openSession` → 新快照）。
     放一个必然失败的按钮，就是项目里反复记过的那类"点了没用"的假入口。
2. **失败就直接 `openSession(sid)` 自动恢复**
   - 最强的理由：零点击，用户什么都不用做。
   - 为何被否：`openSession` 会重新订阅并把滚动位置打回最新一条 —— 用户正停在历史那一端，
     自动把他弹回底部是**更坏**的体验。而且它会把一次网络抖动升级成一整窗重放。
3. **把失败塞进现有的 `dsh_center_notice` 居中提示**
   - 最强的理由：不新增组件，走既有通道。
   - 为何被否：居中的提示 3 秒就消失，而这条信息要在**用户停在那里的时候**一直在
     （他就是在这个位置滑不动了）。放在那一格才叫"说在发生的地方"。

## Consequences

- 收益：翻页失败从"静默"变成"看得见且可解释"；上端不再刷注定失败的请求
  （每条 `ScrollUpdateNotification` 都记一次失败的话，日志和网络都被污染）。
- 代价：`HistoryFailureNote` 新增一个文件（进 `verify-size` 的默认 800 行上限内，无需上表）。
  `chat_page.dart` 只多了 `cellCount` 与一个 `if` —— 棘轮把 `chat_page` 钉在 5300 行，
  第一次实现时把组件写在里面直接红了，于是拆成独立文件。**那条门禁当场起了它该起的作用。**
- 代价：恢复路径靠用户重进会话，没有自动恢复。这是契约给的动作，不是缺省。
- **清点也在这一批做掉了**：`_historyFailure[sid]` 原来只在 `loadOlderHistory` 成功时清除，
  于是重进会话后（新快照已经到了）那条提示还会永远挂着。现在 `openSession` 里
  `client.subscribe` 成功之后清一次 —— "重新订阅成功"正是那个失败的判据失效的时点。
  用例第 3 条的尾巴钉住它（重进 ⇒ 提示消失）；变异校验：删掉那一行 ⇒ 立刻红。
