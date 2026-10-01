# Agent Note: connector 的协议层自持实现，中转与手机侧在测试里是替身

Status: implemented

## Problem

协议的可执行规格是 `protocol/fixtures/`，两侧实现各自对着它跑（这条已在
`2026-09-30-protocol-fixtures-as-spec.md` 定案）。落到 connector 时冒出三个必须先答的问题：

1. **参考实现不是可搬运的代码。** `protocol/reference/*.mjs` 是行为基准，明确定义为「不是产品代码」。
   connector 需要的是能装进 DSH profile 的 TS，所以必须重写一遍 —— 而重写就有抄漏的可能。
2. **三角色拓扑里有两个角色在 connector 里根本不是产品代码。** fixture 的每个场景都是
   「手机 ⇄ 中转 ⇄ 电脑侧桥接」：connector 只实现桥接。中转属于 `relay/`（还没开始），
   手机侧属于 Dart（`app/`，也还没开始）。可 `protocol/verify-fixtures.mjs` 是把三者都塞在一个
   文件里的，直接照搬会把中转与手机端的逻辑写进 connector 的产品代码。
3. **「跑绿了」证明不了「没抄漏断言」。** 如果移植时少抄了十条断言，测试照样全绿 ——
   而且绿得更有欺骗性，因为漏掉的恰恰可能是没通过的那几条。

## Decision

connector 的 `src/protocol/` 是**产品代码**：`frame.ts`（帧词汇与路由视图）、`items.ts`
（itemId 与 upsert 排序）、`dedupe.ts`（幂等表）、`recovery.ts`（修订号、有界缓冲、两种恢复回答、
快照分页、待审批重建、瞬时事实）、`takeover.ts`（接管判定）。

中转与手机侧**只作为测试替身**存在，不进 `src/`：中转放在 `tests/support/relay.ts`，
手机侧（`since` / `received` / `upsert` / `applyAnswer`）留在 `tests/fixtures.test.ts` 内部。

判据 harness 逐条移植 `protocol/verify-fixtures.mjs`，并把**断言总数硬编码为规格常量**
`REFERENCE_CHECK_COUNT = 486`，测试同时断言「零失败」与「断言数相等」。

准入门槛（可机械判定）：

1. `src/protocol/` **不得 import 任何 DSH 类型**，也不得 import `tests/`。
2. **中转与手机侧的逻辑不得出现在 `src/`**；它们只能存在于 `tests/`。
3. `pnpm test` 必须同时满足：`failures.length === 0` **且** `checks === 486`。数量对不上即失败。
4. 改断言时必须做一次**变异校验**：故意破坏 `src/protocol/` 的一条不变量，确认测试真的变红，
   然后还原。没做过变异校验的断言不算数。
5. 协议有变动时**先改 `protocol/fixtures/`**，再改本侧实现 —— 不允许本侧自留一份协议说明。

## Alternatives considered

1. 测试直接 import `protocol/reference/*.mjs`，不重写
   - 最强的理由：零重复、零抄漏，永远与参考实现逐字一致；参考实现本来就跑得通，接上去立刻全绿。
   - 为何被否：参考实现是**行为基准**而不是产品代码（`2026-09-30-protocol-fixtures-as-spec.md` 已定案，
   它明确写了「不能直接搬进插件或 App，两边都得照它重写」）。更关键的是，直接复用会让
   「两侧实现是否收敛」变成**同一份代码自证**——而两侧各自实现的差异正是 fixtures 要抓的东西。
   那样做测试依然全绿，但它证明的东西从「两侧一致」缩水成了「同一份代码等于自己」。
2. 把 harness 抽成共享模块，两侧都 import
   - 最强的理由：断言逻辑只写一遍，486 天然一致，根本不存在「抄漏断言」这个问题；
   将来改判据也只有一处要改。
   - 为何被否：手机侧是 **Dart**，共享 TS runner 对它毫无意义——它无论如何都要自己写一份 runner。
   于是共享只对 TS 侧成立，等于把（1）的自证问题缩小一号原样保留：两侧仍然只有一份判断逻辑。
   跨实现校验的价值恰恰来自两套独立实现得出同一批结论。
3. 不硬编码 486，只断言「零失败」
   - 最强的理由：避免把魔数写进代码；fixtures 增删时不必同步改常量，维护面更小。
   - 为何被否：那样就丢掉了**唯一能机械发现「移植时抄漏断言」的信号**。
   486 是参考侧实测产出的规格值（`node protocol/verify-fixtures.mjs` 的输出），是外部给定的事实，
   不是为了让测试通过而凑出来的数——它和新写一条断言来迎合实现是两回事。
4. 让中转也进 `src/protocol/`，拓扑更完整
   - 最强的理由：fixture 的三角色拓扑能在产品代码里完整跑起来，测试与真实部署更接近，读代码时不用切换文件。
   - 为何被否：`docs/cookbook/channel-bootstrap.md` 的移植表已明确 `relay.mjs` → 不需要（中转侧才有）。
   connector 是**电脑侧**插件，把中转实现塞进它的产品代码会让「中转对内容盲」这条安全边界含混——
   而那条边界正是 `07-relay-restart-invariant` 那类 fixture 在守的东西。

## Consequences

- 收益：connector 侧有了可装进 profile 的协议实现（TS，零 DSH 依赖，可纯 Node 跑）；两侧跑同一批
  fixtures 且断言数**可机械比对**，抄漏断言会在测试里直接报出来而不是静默通过；中转与手机侧的
  「测试替身」身份写在目录结构上（`tests/support/` 与测试文件内），不会被误当产品代码；
  `src/protocol/` 与 `tests/` 的依赖方向单向，第 4 步接 DSH 适配层时不会污染协议层。
- 代价：harness 是移植来的副本，`protocol/verify-fixtures.mjs` 改判据时 connector 侧**不会自动跟**——
  它靠 486 这个数字报警，而不是靠编译器或类型；fixtures 增删后两侧都要同步改常量；
  486 硬编码在测试里，是一处必须记得维护的耦合；测试替身（`tests/support/relay.ts` 与测试内的手机侧）
  与真实实现之间仍然有差距——它们是**按参考实现的语义**写的，真正的一致性要等第 4 步之后对着真机验，
  在那之前「两侧跑同一批 fixtures」只证明了会话层语义一致，不证明连接层可用。
