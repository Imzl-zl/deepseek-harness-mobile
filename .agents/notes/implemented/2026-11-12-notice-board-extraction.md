# Agent Note: 提醒簇搬出 `AppModel` —— 第二簇（身份 / 该提醒什么 / 已贴哪一份）

Status: implemented

## Problem

`AppModel` 在任务簇搬走之后是 **5215 行 / 177 个方法 / 上限 5250·177**
（`implemented/2026-11-11-job-book-extraction.md` 的"未做"里点名了下一簇：通知簇，
理由是"它的外部依赖面已经清晰"）。

动手前先取证 —— 按 `tools.md` 的判据"**拆分的信号是重复的清单与缺失的所有者**"，
数这一段（`app_model.dart:3005-3260`）的三个可变字段与它们的写点：

| 字段 | 写点 | 说明 |
|---|---|---|
| `_appForeground` | 2（初值 + `setAppForeground`） | 跨簇：它同时喂**提醒**与**保活** |
| `_notifyGranted` | 2（`requestNotifyPermission` / `_syncKeepAlive`） | 跨簇：平台真值，两个消费者 |
| `_activeNotices` | 5（应答失效 drop、应答抛错 drop、差集撤、差集贴、`dispose` 清） | 本簇的内部状态 |

然后是两个"没有主人"的清单：

| 事实 | 重复几处 | 具体 |
|---|---|---|
| 一条通知的身份 = `noticeIdOf(keyOf(kind, id))`，键带电脑前缀 | **6** | 审批 ×3（期望集合 1 + 应答路径 2）、提问、任务、整轮完成 |
| "撤掉一条已经贴过的" | **4** | 应答失效、应答抛错、差集收尾、`dispose` |

也就是说：**有第二份清单、也有缺失的所有者** —— 一段 255 行的代码里，"一条通知是谁"
被手抄了 6 次（其中 `_answerFromNotification` 里同一个表达式写了两遍，只差一个变量名），
而"该提醒什么"的四类判据埋在一个 5000 行的类中段。按判据该拆。

## Decision

新建 **`app/lib/data/notices.dart`**（226 行），装三件东西 ——

| 名字 | 原来在 `AppModel` |
|---|---|
| `noticeKeyOf` / `noticeIdFor` / `approvalNoticeId` | `_noticeKeyOf` + 6 处 `noticeIdOf(_noticeKeyOf(...))` |
| `desiredNotices({...})`（自由函数） | `_desiredNotices()`（审批 / 提问 / 任务窗口 / 整轮完成四类判据） |
| `NoticeBoard`（`reconcile` / `drop` / `clear`） | `_activeNotices` + `_syncNotices` 的差集 + 三处"撤一条" |
| `kJobNoticeWindow`（30 分钟） | `_jobNoticeWindow` |

**边界写在文件头**（同 `JobBook` 的三条）：

- `notices.dart` **不认识端口**：它不调 `NotifyPort.show` / `cancel`，
  `reconcile` 只回答"该贴这几条、该撤这几个 id"，由 `AppModel` 去贴去撤。
- 它 **不认识 `AppModel`**：需要会话条目 / 任务行 / 未读标记的地方，调用方**传函数**
  （`itemsOf` / `jobsOf` / `completionUnreadOf`），其余是标量（`hostId` / 前后台 /
  可见性 / 当前会话 / `nowMs`）。`nowMs` 由调用方给，于是"30 分钟窗口"的边界用例
  不需要真的等 30 分钟。
- 它 **不发通知**（不碰 `notifyListeners`）、**不落盘**（已贴的那批是派生状态）。

**留在 `AppModel` 的两件**：`_appForeground` / `_notifyGranted` 与它们的消费者
（`setAppForeground` / `connectionForeground` / `reportToClient` / `_syncKeepAlive` /
`requestNotifyPermission`）。理由：这两个字段**同时喂保活**（前台服务）与提醒，
而保活要读 `client.state`、要经 `AppServices` 汇总 —— 把它一起搬走就要给新类一个
"连接状态 + 服务汇总"的端口，那是**替宿主多设一层边界**，而这一批要解决的只是
"同一件事被表达了 6 次"。

`_syncNotices()` 仍是 `AppModel` 的入口（7 个调用点一行没动），它现在只做一件事：
把本类的事实交给 `desiredNotices`，再把 `reconcile` 的动作转给端口。

## 准入判据

| 判据 | 结果 |
|---|---|
| `cd app; flutter test test/notice_test.dart` | **16 项全绿，用例零改动** |
| `cd app; flutter test` | **1881 项全绿，用例零改动**（搬移的主判据） |
| `dart analyze --fatal-infos lib test integration_test` | 0 |
| `node app/tools/verify-size.mjs` | 19 条自检 + **`AppModel` 5250 → 5150 行 / 177 → 175 方法**（实测 5127 / 175） |
| `node app/tools/verify-platform-boundary.mjs` | 全绿（`data/notices.dart` 只 import `core/` 与 `model/`，不碰 `dart:io` / Flutter） |

变异校验（每条都先 `grep` 确认变异落地；都在 `notices.dart` 上做，跑完 `git checkout` 级还原）：

| 变异 | 结果 |
|---|---|
| `noticeKeyOf` 不再带电脑前缀（`'$kind:$id'`） | **2 红**，恰好是那两条跨电脑 id 用例（"撤一台不动另一台" / "移除一台只撤它贴的那批"）|
| `kJobNoticeWindow` 改成 `Duration.zero` | **4 红**，恰好是四条任务提醒用例（含"30 分钟窗口"那条）|
| `reconcile` 里"消失的那批"不再撤（`continue`） | **4 红**，恰好是四条"撤掉"用例（decided / 切过去 / 两台 id / 池中不可见那台）|

三条变异都精准命中，说明 `notice_test` 的 16 项确实盯着搬走的那段逻辑
（而不是"碰巧也绿"）。

## Alternatives considered

1. **把整簇（含 `_appForeground` / `_notifyGranted` / 保活）一起搬走**
   - 最强的理由：那才是"通知"这个词的全部，文件内聚度最高。
   - 为何被否：保活的判据要读 `client.state`、要经 `AppServices.syncKeepAlive` 汇总
     多台电脑的诉求；把它们搬进 `notices.dart` 就要给新类一个"连接状态 + 服务汇总 + 监听"
     的端口 —— 三件事一个接口，而实现只有一个（就是 `AppModel`）。
     **一个实现换不来一个接口**（本仓 `AGENTS.md` 的"按证据抽象"）。
     真要搬，得先出现第二个消费者。
2. **只搬 `NoticeBoard`（不动 `desiredNotices`）**
   - 最强的理由：搬得更少，风险更低。
   - 为何被否：那正好是"拆了只是搬家" —— 盘子里没有主人（一个 map + 三个方法）。
     这一批真正的收益是**"哪四类事值得提醒"离开 5000 行的类**：它是唯一会随
     "新增一种提醒"变动的地方。只搬板子等于把收益留在了原地。
3. **只搬 `desiredNotices`，把 `_activeNotices` 留在 `AppModel`**
   - 最强的理由：状态留下、纯函数出去，是最小切口。
   - 为何被否：6 处身份拼接里的 5 处在 `desiredNotices` 内，但第 6 处
     （应答路径上的 `approvalNoticeId`）留在外面就还要 `_noticeKeyOf`；
     而"撤一条"的四处重复也还在。身份与板子必须同住，否则那个"唯一算法"又多了一层转发。
4. **不拆（判为"只是搬家"）**
   - 最强的理由：这一簇只有 3 个字段，5 个写点，看起来不像任务簇那样成块。
   - 为何被否：反证就在上面那两张表 —— **6 处身份 + 4 处撤销**。那不是"数量小"，
     那是"同一件事没有主人"。判据是重复的清单，不是行数。
5. **给 `desiredNotices` 建一个 `NoticeFacts` 接口（而不是传函数）**
   - 最强的理由：9 个参数读起来吓人，接口会让签名更干净。
   - 为何被否：接口只有一个实现（`AppModel`），而函数参数已经表达了同一件事，
     代价是多一个类型与一次"这个接口谁实现"的跳转。**将来出现第二个事实源**
     （比如"离线模式下也算提醒"）时再抽，那时才有第二条实现可对齐。

## Consequences

- 收益：`AppModel` **5215 → 5127 行 / 177 → 175 方法**，上限收到 **5150 / 175**。
  方法数掉两个不是巧合：`_noticeKeyOf` 与 `_desiredNotices` 消失了，
  而新的自由函数与 `NoticeBoard` 不计入那一格（这也正是收窄该有的形状）。
- 收益：「哪四类事值得提醒」与「一条通知是谁」第一次有了名字与住处，
  且都在 `AppModel` 之外 —— 需要时可以纯 Dart 单测（`desiredNotices` 只吃事实）。
- 收益：应答路径上那个**同一个表达式写两遍**（`final stale = …` / `final id = …`）
  合成一个局部变量 `noticeId`，两处"撤掉这条"都走 `_notices.drop(noticeId)`。
- 代价：`desiredNotices` 的签名有 9 个参数（其中 3 个是函数）。读它的人要认一遍
  "这些事实从哪来"。这是刻意的：它换来的是"这个文件不认识 `AppModel`"。
- 代价：`_syncNotices` 现在两跳（先算 diff、再贴撤）。原来是一跳。
  行数少了一半（记忆差集搬进了 `NoticeBoard`），但**调用链多了一层**。
- 未做：`_sidOfPendingItem` 仍留在 `AppModel` —— 它读的是"已订阅会话的本地条目"，
  与 `_pendingCountOf` 同一个数据面；搬它要连带那个数据面，而这一批的判据是
  提醒簇。它只被应答路径用到一处。
- 未做：**`AppModel` 仍是 5127 行**。下一簇按 `proposed/2026-10-27-ui-state-design.md`
  的顺序是**会话执行簇**（发消息 / 取消 / 翻页 / 恢复），而它是与 `_stores` / `_rows` /
  水位 / 投影纠缠最紧的一块 —— 先得把 `_stores` 的所有者定下来
  （`proposed/2026-11-11-session-memory-compaction.md` 列了四个边角）。
- 未做：这一批**没有新增用例**。`desiredNotices` 现在可以被单测，但它今天的所有
  判据都已经被 `notice_test` 的 16 项通过 `AppModel` 覆盖到了 —— 再抄一遍就是
  "用例重述实现"。真要加，该加"纯函数能测"以外的东西（比如第二种事实来源）。
