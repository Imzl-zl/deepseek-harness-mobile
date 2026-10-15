# Agent Note: 投影信封必须拆在连接器，而替身必须复现真值的形状

Status: implemented

## Problem

`session.projections` 接上之后，手机上那些只读面**一个都没亮**：统计条、上下文环、
子智能体面板全是空态，而 `session_projections_test.dart`（8 条）与
`subagent_panel_test.dart` 全绿。

根因不在解析，在**形状**：DSH 的 `@Remote('projections')` 返回类型是
`SessionProjectionValue` 联合（`packages/api/session-controller/src/index.ts:507`）——
`null`（会话不存在）或 `{kind: 'sequenced' | 'migration-required', asOfSeq, values}`。
连接器把这个信封**原样透传**，于是手机拿到的 Map 的键是 `kind` / `asOfSeq` / `values`，
`tokenUsage` / `permissions` / `subagentCatalog` **一个都取不到**。

而单测全绿的原因更值得记：测试替身直接返回 `values` 映射
（`fakeController(values)` 里 `return values`），**绕开了信封**。
替身照"手机要的形状"写，于是它证明的是别的东西。

## Decision

**信封拆在连接器**（`connector/src/dsh/projections.ts` 的 `valuesOf`）：
给手机的是 `values` 映射 —— 契约 §5.7 承诺的本来就是"所有已注册投影的当前值"，
`kind` / `asOfSeq` 是 DSH 自己的传输细节。`null`（会话不存在）与"没有 `values` 字段"
都归一成**空映射**而不是 `null`：空映射让所有只读面一致地显示空态，
而回 `null` 会让 `AppModel.refreshProjections` 早退，于是**上一次的旧值继续显示**。

**替身必须复现真值的形状**：`connector/tests/session-projections.test.ts` 的假控制器
现在包一层 DSH 的信封（`{kind, asOfSeq, values}`），并有一条专们钉
"`kind` / `asOfSeq` 不过线"。这是本产出的真正判据 —— 没有它，
下次有人改透传逻辑，单测照样全绿。

准入门槛（可机械判定）：

1. 假控制器返回 `{kind, asOfSeq, values}` 而不是 `values`；
2. 有一条断言 `'kind' in result === false`；
3. DSH 回 `null` 时给空映射，不是 `null`。

变异校验：把 `valuesOf(value)` 换回 `return value`（即还原那个 bug）→
**恰好 3 条红**（信封不过线、`migration-required`、`null` → 空映射），其余全绿。

## Alternatives considered

1. 在手机侧拆信封（`AppModel.refreshProjections` 读 `result['values']`）
   - 最强的理由：连接器一行不改，契约"原样透传"那句话也不用动；
     而手机本来就在解析 DSH 的投影形状（`tokenUsage` 的字段名就在 Dart 侧），
     多认一个 `kind` 不算新知识。
   - 为何被否：那会把 DSH 的**传输层联合类型**（含 `migration-required` 这个分支）
     搬进手机。连接器的职责就是把"DSH 怎么说"与"手机看到什么"分开；
     而契约 §5.7 的文字描述的一直是 values 映射，透传信封本身就是与契约不符的实现。
2. 连信封带 `asOfSeq` 一起透传，手机将来自己用
   - 最强的理由：`asOfSeq` 是"所有值共同反映到哪个 seq"，将来做"事件到了本地折一遍"
     要用它（投影本来就是事件的折叠）。
   - 为何被否：本期没有任何消费者。为一个想象中的用法保留一层嵌套，
     代价是每个读投影的地方都要多解一次 —— 而"将来可能要用"正是最容易腐化的设计。
     真到那天，加一个字段比拆一层嵌套便宜。
3. 只修测试替身，不动产品代码
   - 最强的理由：改动最小，而且"替身不真实"确实是问题的一部分。
   - 为何被否：产品代码仍然是错的。修替身只是让测试有机会发现 bug，
     不改变"生产里统计条是空的"这个事实。

## Consequences

- 收益：统计条、上下文环、子智能体面板、权限档**在生产里第一次真的亮**；
   `session.projections` 这一条链从"接了但没通"变成通了。
   `refreshProjections` 顺手改成兜住所有异常（与 `refreshSessions` 同一条纪律）——
   之前只接 `ProtocolException`，一个解析错就会让 `openSession` 半途而废。
- 代价：
  - `dsh/projections.ts` 的"原样透传，不挑字段"纪律收窄成"不挑**投影键**"：
    信封要拆，但 `values` 里一个键都不许挑（`viewSchema` 是 zod `.strict()`，
     而我们不该预先知道全部键）。
  - 手机侧少一个 `asOfSeq`（见 Alternatives 2）。

代码回指：`connector/src/dsh/projections.ts` 的 `valuesOf`、
`connector/tests/session-projections.test.ts` 的假控制器。
