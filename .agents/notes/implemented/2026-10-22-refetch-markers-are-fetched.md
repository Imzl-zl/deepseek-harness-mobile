# Agent Note: 翻页里的 refetch 标记必须补取，不许跳过

Status: implemented

## Problem

契约 §5.3 规定：单个条目封箱后 > 1 MiB 就不推内容、推一个
`{kind:'refetch', seq, bytes}` 标记，由手机按需 `session.refetch` 补取
（`connector/src/session-page.ts:103-110` 出标记、`:115-139` 补取）。
连接器侧一直是完整的（`refetchThresholdBytes` 默认 1 MiB，`connector/src/config.ts:61`）。

而手机侧 `page()` 只留 `{kind:'record'}` 的项，**`refetch` 标记被直接跳过**。
后果不是报错、也不是缺页，而是**会话里少一条**：>1 MiB 的条目
（图片内联在 `assistant/message` 里，`packages/api/session-controller/src/types.ts:89-97`）
在手机上永远看不到，而界面上一切正常。2026-10-22 的静态审查发现了它
（`docs/subsystems/subagent-page.md` §7.3）。

## Decision

`SyncClient` 增加 `refetch({sid, seq})`；`page()` 遇到 `refetch` 标记就补取，
把事件按 `seq` 并进这一页。补取失败**不吞**：整页判失败（`SessionPage.failure`），
上层不落半页。

准入门槛（可机械判定）：

1. **标记必须换一次补取**：`page()` 里每个 `refetch` 项都要发出一次
   `session.refetch`（参数是 `{sid, seq}`），并把它返回的事件放进 `events`
   （`sync_client_test.dart` 的「标记 → 调 session.refetch → 那一条出现在这一页里」）。
2. **失败如实报**：补取被拒时 `failure` 是那个线上码（如 `session/not-found`）、
   `events` 为空 —— 宁可整页失败，也不留一个静默的洞（同文件第二条）。
3. **形状错也吵**：标记没有 `seq` 时抛 `protocol/bad-frame`（对端的形状错，
   不是"没有这一条"）。
4. **替身不编数据**：`FakeSyncClient.refetch` 默认**抛** `UnimplementedError` ——
   返回一条假事件会让"大条目出现了"这个断言在假数据上变绿。

## Alternatives considered

1. **把标记原样交给上层（`SessionPage` 带 `refetchSeqs`），由 `AppModel` 补取**
   - 最强的理由：`core/` 只做搬运、不做业务，补取与合并属于"落到会话里"那一层；
     将来别的调用方（比如只读的轨迹页）也能复用同一份标记。
   - 为何被否：补取的输入是**连接层的水位**（`throughSeq` 来自订阅面开启帧），
     而 `AppModel` 拿不到它；把标记带出去等于把"这一页不完整"这个事实
     泄露给三个调用方，各自都要再实现一次补取。
2. **在 `AppModel.loadOlderHistory` 里补取（按 `page.events` 与标记的差集推）**
   - 最强的理由：不动 `core/` 的接口，改动面最小。
   - 为何被否：`page()` 返回的事件表已经把标记丢了，上层**推不出**少了哪几条
     （只能看到"这一页比预期短"）。要推就得让 `page()` 也把标记带出来 ——
     等于方案 1 再加一层。
3. **给 `SyncClient` 的 `refetch` 一个退化的默认实现（`=> start()` 那种）**
   - 最强的理由：`tools.md` 记着"多替身接口加方法要给默认实现"，看着像省事。
   - 为何被否：Dart 的 `implements` **不继承默认方法**，默认实现救不了替身；
     而且 `refetch` 没有"退化的成功"语义 —— 返回假事件比失败更糟。
     实测全仓只有 3 处要改（`_SyncClient`、`FakeSyncClient`、
     `integration_test/ui_flow_test.dart` 的自实现替身），逐个补比造一个假默认更诚实。

## Consequences

- 收益：>1 MiB 的条目（图片消息、大工具输出）在手机上有内容了；
  `tools.md` 里"给默认实现"那条被纠正成"改替身基类，`implements` 不继承默认方法"。
- 代价：翻一页可能变成 **N+1 次往返**（每个大条目一次补取，串行）；
  一次补取失败会让整页作废（用户要再翻一次）。真机实验把阈值压到 1 字节时，
  这个代价被放大到每条都补取 —— 那正是这条代价的形状。
