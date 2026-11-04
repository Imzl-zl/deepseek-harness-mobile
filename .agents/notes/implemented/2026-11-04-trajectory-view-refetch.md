# Agent Note: 进入轨迹页签就重读一次投影，而不是等某个事件来救

Status: implemented

## Problem

2026-11-04 真机：轨迹页是空态，而且那句话是错的 ——「这台电脑没给时间轴：连接器没有注册
trajectory 投影，升级电脑侧的连接器后才有每一步的起止」。

事实三条：

1. 同一台电脑、同一个连接器（0.1.16），**重启 App 后 20 轮立刻画出来**；
2. 电脑侧的投影缓存里 `turnOutline` 20 条、`trajectory` 20 轮 458 步都在
   （`~/.dsh/storages/session_projcache/sessions/session-54240517-….json`）；
3. 重启前统计条是活的（`20 轮 110 步 · 23.8M tok`）—— 也就是说手机手里**有一份包**，
   里面有 `sessionStats` / `tokenUsage`，只是没有 `turnOutline` / `trajectory` 两个键。

于是问题不是"没有数据"，而是**手里那份包旧了（或缺键），而没有任何机制把它换掉**：

- 这一屏的全部内容都在 `session.projections` 一个包里；
- 那一包的重读时机是封闭登记表里的一列（`app/lib/data/host_state.dart`）：
  `notification` / `openSession` / `connectLanding` / `appResume`；
- 前四个都不覆盖"会话没换、一轮还在跑"：一轮跑二十分钟时 `turn/end` 一次都不来，
  队列没变、没有 `host` 帧、用户也没切会话 —— 一个触发点都没有；
- 空态把"这一包里没有这个键"与"这台电脑没注册投影"合成一句，把人指向升级连接器。

## Decision

**进入轨迹页签本身是一个重取触发点**（`HostStateTrigger.viewFocus` → `AppModel.focusView(sid)`），
并且空态按事实分三档说清，只有"这一包没到"给「重读」。

准入门槛（可机械判定）：

1. **触发点只登记在登记表里**：页面不许直接调 `refreshProjections` —— "何时重取"只有
   `host_state.dart` 一处；`host_state_test.dart` 的"每条 fetch 真的调到它名字指向的方法"
   继续钉住这一条。
2. **空态三档由事实判定**，不许猜：`app.projections == null`（包没到）/
   包非 null 且 `app.trajectory == null`（缺键）/ `trajectory.turns` 为空（没轮次）。
   三档由 `TrajectoryEmptyReason` 一处表达，`trajectory_test.dart` 逐档钉文案。
3. **只给"这一包没到"配动作**：缺键与没轮次都重读不出东西来，摆一个点了没用的按钮
   就是假入口（`trajectory_test.dart` 有一条专门断言缺键时没有「重读」）。

## Alternatives considered

1. 轮询（例如停在这一屏时每 5 秒重读一次）
   - 最强的理由：不依赖用户动作，长回合期间也能自愈，连"用户一直停在轨迹页"都覆盖。
   - 为何被否：DSH 自己是**推送**投影的（`observeProjections` 流），我们这条通道没有那条流；
     编一个"多久问一次"就是替宿主做决定，而且手机要为此常驻一个定时器，只为这一屏。
2. 失败重试（重连时投影读失败就退避重试 N 次）
   - 最强的理由：直接对准"那次失败留下的旧包"，不需要用户操作。
   - 为何被否：次数与间隔同样是编出来的策略；而"进入这一屏就重读"已经把恢复交回给
     用户本来就会做的动作（去看轨迹），再叠一套退避只增加一处需要解释的行为。
3. 让连接器区分 `sequenced` / `migration-required`（把 DSH 信封的 `kind` 过线）
   - 最强的理由：这是唯一能证明"这份包是缓存提示、不是精确快照"的信息，而今天连接器
     把它丢掉了（`connector/src/dsh/projections.ts:68-72` 只取 `values`）。
   - 为何被否（本次）：它要动契约 §5.7（手机拿的就是 `values`），而 2026-11-04 这次会话是
     `session.v4.jsonl` 当前格式、不是迁移态 —— 没有证据说这条路真的发生过。先按
     "进入这一屏重读"把可观察的症状治掉；这条留在 `docs/subsystems/trajectory-page.md` §8
     的已知缺口里，等真出现 `migration-required` 再改契约。
4. 空态保持一句话（只改重取，不改文案）
   - 最强的理由：改动最小，不用加枚举、不用给按钮。
   - 为何被否：这次就是被那句话指错的（用户去查连接器版本），而真正该做的是重读这一包；
     一句错话会把下一次排查也带偏。

## Consequences

- 收益：旧包 / 缺键在**进入这一屏**时自愈，不用重启 App；空态说的事与用户能做的事对齐
  （重读 / 查电脑 / 等一轮）；"何时重取"仍然只有登记表一处，页面没有第二个入口。
- 代价：每次进入轨迹页多一个带摘要的往返 —— 内容没变约 41 B（`{notModified:true}`），
  变了才搬正文；`TrajectoryTab` 多两个参数（`emptyReason` / `onRetry`），
  构造方多一处必须说清"这是哪一种没有"。
- 仍欠着：连接器不区分信封 `kind`（见上第 3 条），今天只是"症状被治住、原因仍说不准"。
