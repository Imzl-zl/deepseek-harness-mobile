# Agent Note: 抽屉按桌面只展开 5 条会话，多出来的收进「展开其余 N」

Status: implemented

## Problem

2026-10-27 用户真机对照桌面：「桌面他不是所有展开，默认展开五个会话列表，
然后下面有一个展开其余 xx 个会话这样」，而手机侧把每个工作区的会话**全渲染**：
一个有 45 条会话的工作区在抽屉里就是 45 行，滚动全被它吃掉。

同一轮还发现抽屉的「搜索会话」是**死控件**：`SessionDrawer.onSearch` 存在，
但装配层（`main.dart`）从来没传，`TextField.onChanged` 拿到的是 `null` ——
能打字、一行都不筛。

## Decision

抽屉的"每组显示多少条"按桌面 watermark 规则算，多的收进一行
「展开其余 {n} 个会话」；搜索在装配层过滤。

准入门槛（可机械判定）：

1. 每组默认只放 `kSessionWatermarkBase = 5` 条**非 blank** 会话
   （桌面 `rows/WorkspaceBrowser.tsx:55`）；blank 行恒显示且不占名额（`:60-70`）。
2. 在跑 / 有子在跑 / 有待处理 / **当前** 的会话不许被裁掉，watermark 抬到刚好
   覆盖它，上限 `kSessionWatermarkAutoMax = 50`（桌面 `requiredWatermark` / `:57`）。
   用例：`app/test/drawer_watermark_test.dart` 前五条。
3. 文案逐字照桌面 `sessions.expand = '展开其余 {n} 个会话'`（`locales.ts:34`）；
   `hiddenCount == 0` 时整行不占位。点它只放这一组，且**不落盘**
   （属"这次打开抽屉想多看几条"的临时意图，与 `host.drawer_expansion` 的
   跨重启折叠记忆不是一回事）。
4. 搜索只筛标题、大小写不敏感，且**筛的是已经算好的可见集** ——
   归档 / blank 那几条可见性规则仍然先跑，搜索不会把不该露的会话翻出来。

## Alternatives considered

1. 照桌面的完整 `requiredWatermark`，把 `unread` / `awaiting` 也算进抬高条件
   - 最强的理由：那是桌面的真判据，少算一种就会在特定状态下把该看见的会话裁掉。
   - 为何被否（本批）：手机侧 `pendingCount` 与 `running` 已经覆盖了
     "在跑 / 有子在跑 / 等你答"三类里可判的部分；`unread`（`completionUnreadOf`）
     与 `pending` 重叠度高，先不引入第二种口径，等真机遇到再说 —— 少算一格是
     已知偏差，不是遗漏。
2. 把 watermark 放进 `SessionDrawer` 里裁
   - 最强的理由：抽屉自己就知道有几行，不必让装配层多传一个字段。
   - 为何被否："哪些会话可见"（归档 / blank / 子会话）本来就在装配层算
     （`sessionVisible` + 分桶）。在抽屉里再裁一次等于第二份可见性真值，
     而搜索也必须用同一份集合 —— 两处必然漂。
3. 「展开其余」落进 `host.drawer_expansion`
   - 最强的理由：一次点击、重启后还在，体验连续。
   - 为何被否：那个键的语义是"这个工作区组折叠了"，与"这一组想多看几条"
     是两个意图；混进同一个 JSON 会让"折叠"与"多显示"互相覆盖。

## Consequences

- 收益：抽屉回到桌面那种密度（每项目 5 行 + 一条展开行）；搜索框从死控件变成
  能用；两处（折叠、展开其余）共用 `SessionDrawer.keyOf` 一个键拼写处。
- 代价：多一个常量与一个纯函数（`model/workspace.dart` 的 `watermarkRowsOf`）；
  「展开其余」的展开态不跨重启，重开抽屉会重新收起（有意，见替代方案 3）。
- 已知偏差：抬高条件比桌面少 `unread` 一档（见替代方案 1）。
