# Agent Note: 「新建会话」的自相矛盾由一道本地判据兜住，不再等清单重读

Status: implemented

## Problem

2026-11-10 真机（另一台手机、公网中转）：会话**已经跑完**，点「新建会话」之后
**顶栏变成「新建会话」，正文还是那段旧对话**；再点 ＋ 也一动不动。

标题与正文来自同一次 build，所以问题不在"切会话"，在那个会话的**行**：

- `blank` 是宿主的字段（`blank && type !== 'turn/start'`，
  `packages/api/session-controller/src/list.ts:51`），手机手里的那一行是**缓存**；
- 缓存只在**重读 `session.list`** 时更新，而重读靠 `session/title` 之类的通知
  （`connector/src/protocol/host-state.ts` 的 `hostStateForSessionEvent`）：
  自己发消息**不**重读（在 `turn/start` 重读会把 `running` 压旧，见
  `app_model.dart` 的 `_onDelta` 注释）。
- 那条通知一旦没落地（中转抖动 / 进程被冻结 / 那次重取失败），行就停在那里：
  `displayTitle` 里 **blank 压过 title**（与 DSH `tree.ts:287` 同形）⇒ 顶栏写
  「新建会话」；正文照旧画同一个会话 ⇒ "还是旧会话"；
  `findBlankSession` 又把这个会话当新会话 ⇒ `openSession(自己)` ⇒ 再点也没反应。

同一天真机 A/B 已证：在**健康连接**上这条会自愈（标题事件 ~1 秒内就把整行刷真，
实测顶栏从「新建会话」变成真标题）。所以它是**丢一次通知就永久卡住**的那类状态，
现场丢了哪一条我复现不出来 —— **这一篇不解释"为什么丢"，只保证"丢了也不出错"**。

## Decision

会话"还算不算新会话"这件事收成**一道判据**（`AppModel.sessionBlankOf`）：
宿主说 `blank`，**并且**手里没有可见条目。
`OtherItem` 不算可见条目 —— 那与 hero 原有的判据同一个口径
（`docs/subsystems/blank-session-hero.md` §5，上下文注入不该把 hero 顶掉）。

消费点全部走它：顶栏标题（`currentTitle`）、hero（`currentIsBlank`）、
复用（`findBlankSession`）、抽屉的可见性 / 行标签 / 副标题、主界面内联列表、
抽屉的分页水位（`watermarkRowsOf` 的 `isBlank`）。

准入门槛（可机械判定）：

1. 单测：`session.list` 给一行 `blank: true`，再从 delta 推一条**真形状**的
   `user/message`（清单没重读）⇒ `currentIsBlank` 为假、`currentTitle` 不是
   「新建会话」、`findBlankSession()` 为 `null`
   （`app/test/new_session_workspace_test.dart` 的「折回」）。
2. **变异校验**：把 `sessionBlankOf` 的中段改成恒 `true`，**恰好**第一条断言红。
3. 不许再出现"只看 `row.blank`"的第六个消费点：新增消费点时用 `sessionBlankOf` /
   `hasVisibleItemsOf`（`chat_page.dart` 的 `_SessionListInline` 为此收了一个
   `isBlank` 入参，没让它自己去读行）。

## Alternatives considered

1. 收到任何会话事件就重读 `session.list`
   - 最强的理由：真值只有宿主一份，手机完全不用推断。
   - 为何被否：`session.list` 在宿主上是重活（本机 327 会话 / 539 MB 日志那次量过），
     而且快照会把刚到的 `running` 压回旧值 —— 这条回归 2026-10 已经踩过一次
     （`running_reconnect_test` 钉住）。
2. 给 `session.list` 加一个"这一行是否可信 / 什么时候取的"时间戳，过期就重取
   - 最强的理由：能同时拿到"别用旧行"和"别每次都拉整表"。
   - 为何被否：又多一份时间语义要维护，而本地条目已经把话说清楚了；
     "手里有内容"比"行是哪一秒取的"更直接。
3. 只在 UI 层兜（比如顶栏发现 `currentIsBlank` 与条目矛盾就不显示「新建会话」）
   - 最强的理由：改一处，不动数据层。
   - 为何被否：复用判据（`findBlankSession`）与抽屉可见性也在读同一个矛盾值 ——
     只在顶栏兜，就会变成"标题对了、点 ＋ 还是没反应"的那一半 bug。

## Consequences

- 收益：一行陈旧不再能同时骗过顶栏、hero、复用判据与抽屉；
  「标题说新会话、正文是旧对话、点 ＋ 没反应」这个组合被一道本地判据切断。
- 代价：`blank` 现在有两个来源（宿主的字段 + 本地可见条目），
  但它俩冲突时的裁决方向是固定的（**以手里的内容为准**），且只有一处实现；
  口径与 hero 的 `hasVisibleItems` 合成一处后，`chat_page` 不再自己算一遍。
- 未做 / 未证：**通知为什么会丢**没查出来（中转侧只做字节转发，代码上看不出会吞帧）。
  下次真出现时，第一件事是抓那一刻的 `session.list` 与 `host` 帧，而不是先改判据。
