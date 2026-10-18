# Agent Note: hero 在真机上从未显示 —— `items.isEmpty` 被记账事件击穿

Status: implemented

## Problem

2026-10-17 真机验收（用户换局域网、重新配对后连上）发现：连上后落在 blank 会话，
占位文案已经换成 hero 那句（「描述你想要构建的内容…」），但对话区**一片空白** ——
鱼、「探索未至之境」、「预览版」、两枚 chip 全都不在。电脑侧会话日志为证：**每个**
会话的头几条都是 `session` / `permission/preset` / `sandbox/mode` / `approval/policy`
这些记账事件；手机投影层把不认识的事件类型投影成 `OtherItem`（只计数、不渲染，
`_TurnView` 映射成 `SizedBox.shrink`），于是 `items.isEmpty` 在真机上**永远为假**，
`_ChatTab` 的 hero 分支一次都没进过。

规格（`docs/subsystems/blank-session-hero.md` §5）写的判据是 **blank 本身**
（"blank 会话 → hero;其余空屏 → 原来的空态"），实现却自造了一个替身判据
（条目数为零）。单测 14 项全绿的原因：`_HeroClient.sessionUpdates` 返回
`Stream.empty()`，store 永远是空的 —— 本仓第四个"替身复现的不是真形状"
（前三个：投影信封、模型目录形状、`session/select-model` 约束，见 `memory.md`）。

## Decision

hero 的判据从 `items.isEmpty`（条目数为零）改成 **blank 本身 + 没有可见内容**
（`items.any((item) => item is! OtherItem)` 取反），并把这个判断挪到 items 分支之前。
占位符一侧（`_heroVisible`）本来就不看条目数，两边从此只认同一件事。

准入门槛（可机械判定）：

1. hero 出现 ⇔ `isBlank && serving && 没有可见条目`；三者任一不满足都不出现。
2. 刚发出、轮次还没起的用户消息是**可见**条目：那时照常渲染消息流，不进 hero
   （"消息发出去了却看不到"比"hero 晚一步出现"糟得多）。
3. 回归测试必须推**真形状**（四条记账事件 + 一条用户消息两个用例），空 store 的
   旧用例对此类问题一无所知。

## Alternatives considered

1. 让投影层把记账事件丢成 `null`（不进条目表）
   - 最强的理由：条目表从此只含可见内容，`items.isEmpty` 恢复"没有内容"的语义，
     hero 的判据一行都不用动。
   - 为何被否：`OtherItem` 的存在是投影层刻意的纪律（"未知类型不丢"，否则
     "事件总数与条目数对不上"无从排查，DSH 的事件类型会随上游增加）。为 UI 的
     一个判据去改投影层的保全纪律是反的；而且 `command/run` 之类的事件确实
     "发生了、没有渲染位"，丢掉它们等于让诊断线索消失。
2. 在连接器侧过滤记账事件，根本不下发给手机
   - 最强的理由：手机上反正不渲染，投影层也不用认识这些类型。
   - 为何被否：契约 §5 的恢复语义只有"增量或快照"两种结果，按类型过滤会让
     seq 连续性与事件计数对不上；且手机侧 `_projectionFailures` 的诊断要靠
     "收到过"才能说话。
3. 保留 `items.isEmpty`，给 `ItemStore` 加一个 `visibleItems` getter
   - 最强的理由：语义直白，且"可见"从此是模型层的一等概念。
   - 为何被否：可见性是 `_TurnView` 的决定（它把 `OtherItem` 映射成
     `SizedBox.shrink`），放进 model 层就成了**第二个真值源** —— 将来新增一种
     "不渲染"的条目类型时，两处必须同步改，而它们会漂。判据留在使用它的 UI 层，
     与 `_TurnView` 同文件，改一种类型时看得见彼此。

## Consequences

- 收益：真机上 hero 第一次能显示（连上后的第一屏终于长成 DSH 的新会话页）；
  判据与规格一致；占位文案与 hero 不可能再不一致（两边都只认 blank + 连接态）。
- 代价：`_ChatTab` 每次 build 多一次 O(n) 扫描（n = 条目数，量级 <100，可忽略）。
- 代价："可见"的判据（`OtherItem` 不可见）表达在 UI 层，将来新增"不渲染"的
  条目类型时必须同步这里 —— 已在判据处的注释里钉住，并指向本篇。
- 观测点：`app/test/conversation_hero_test.dart` 的「记账事件不挡住 hero」与
  「可见条目进消息流」两条（13 → 16 中的新增两条）；真机复验截图
  `mock/proto/shots/accept-*.png`（该目录不入库）。
