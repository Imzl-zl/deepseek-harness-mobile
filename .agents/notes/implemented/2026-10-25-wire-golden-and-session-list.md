# 线上形状（RPC 应答）：金样机器（第 0 批）

- 日期：2026-10-25
- 状态：已落地（**第 0 批已完成**；第 1 批及以后逐批在本篇追加）
- 规格：`proposed/2026-10-25-wire-design-review.md`（本轮开工单
  `proposed/2026-10-25-wire-batch0-and-batch1-prompt.md`）
- 相关：`implemented/2026-10-25-event-wire-single-decoder.md`（事件面已落地，本篇沿用它的三态内核）、
  `implemented/2026-10-15-projections-envelope-must-be-unwrapped.md`（第二次事故的修法落在生产者侧）、
  `implemented/2026-10-24-plan-review-card-from-request.md`（第三次事故）、`memory.md` 教训第九条

## Problem

事件面收口之后，**RPC 应答面还是老样子**：`app/lib/data/app_model.dart` 里 41 个读取点、
104 个字面量字段，全是 `result is Map ? result['x'] : null`。形状错了不会有任何声音 ——
2026-10-15（投影信封装错层）与 2026-10-24（计划卡的 `arguments` 按对象读）都是这么过的。

规格笔记为此定了"金样"这条路，但第一版草案写的是**真样本快照**（桌面跑一次 App 抓 ~20 个方法的应答）。
这条路不成立，而且不成立的方式很阴：**真样本是一次性快照，连接器改了应答它不会变。**
于是用例永远绿 —— 与教训第九条（"用例喂的形状不是线上形状"）逐字同形，
只是把"手捏的形状"换成了"过期的真形状"。抓一份真样本还需要电脑侧起实例、配模型，
它把一道每天都要跑的门禁绑在了一次性的手工动作上。

**本轮先落机器，再搬第一个面。** 没有金样，后面七批的"验收"都只是"用例绿"，
而那正是三次事故里全绿的那个绿。

## Decision

**形状的真值在生产者（连接器），判据是一份由连接器的测试从真实 handler 生成、深比较守住的
金样；App 的用例读同一份文件。**

准入门槛（可机械判定）：

1. **金样按"方法名 → 样本数组"**，`connector/tests/fixtures/wire-shapes.json` 入库；
   数组是必须的 —— 同一个名字在线上可能有**两种形状**（见下条）。
2. **比较必须在"线上那一层"**：比 `JSON.parse(JSON.stringify(result))`，不比 JS 对象 ——
   `{a: undefined}` 与 `{}` 在 JS 里不相等、在线上是同一件事。
3. **只有 `UPDATE_WIRE_SHAPES=1` 才写盘**（快照测试的老做法），平时只比较；
   键集合与 `SAMPLES` 对不上、某方法一条样本都没有 ⇒ 红（缩水会让 App 侧断言在空集上全绿）。
4. **App 侧一条"金样在就不会空跑"的用例**：文件缺失**直接 `fail`，不许 `skip`**。
5. **采样必须确定性**：假 id 走 `tests/support/fake-aliases.ts` 的定值表，行里没有时间戳、
   没有随机值；另有一条"采两遍必须一模一样"的用例把它按住。

本轮收进金样的两个方法，**故意是同一个名字的两种形状**：

| 位置 | 形状 | 出处 |
|---|---|---|
| `session.list` 行里的 `.projections` | **完整信封** `{kind, asOfSeq, values}` | `connector/src/dsh/sessions.ts:333-341`、`handlers.ts:766-768` |
| `session.projections` 的**应答** | **扁平 `values`**（无信封、永不 `null`，`null` → `{}`） | `connector/src/dsh/projections.ts:68-72`、`:94` |

两个决定各自都有理由（"拆信封"是第二次事故的修法；"原样透传不挑键"是
`dsh/sessions.ts:155-161` 的注释），合起来就是一个 50% 会踩的坑，而踩错的表现为**静默空值**。
单靠"每个方法一个 decoder"抓不到它 —— 能抓住它的唯一形态是**金样里两种形状并存，谁读错谁红**。

## Alternatives considered

1. **真样本快照（第一版草案的路）**
   - 最强的理由：零新增测试代码 —— 抓一次就是一门外加的真实形状，比手写用例可信。
   - 为何被否：**它不随实现变化**。连接器改了应答，用例照旧绿，而那正是三次事故里的那个绿。
     另外它把门禁绑在"电脑侧起实例 + 配模型"的一次性手工动作上，每天跑不了。
2. **运行时 schema 校验（每个方法一张 JSON Schema）**
   - 最强的理由：形状错误在**进入系统之前**就被拦住，消费端可以完全不设防。
   - 为何被否：schema 与 decoder 是两份要同步的真值，而我们需要的恰恰不是"通用校验"，
     是"这 46 个方法的字段各是什么类型、从哪一层取"。它可行的形态就是本篇的机制（用生产输出当金样），
     不是手写 schema。
3. **从连接器 TS 类型 codegen 出 Dart**
   - 最强的理由：形状永远与生产者一致，漂移在**编译期**响，比任何回放都强。
   - 为何被否（**今天不可选，不是不好**）：没有类型源 —— `MethodHandler` 返回 `Promise<unknown>`
     （`connector/src/protocol/methods.ts:280-283`），`METHODS` 只是 49 个字符串。
     要 codegen 得先写 46 个应答类型，那就是"把形状责任推回连接器"，成本是金样的几十倍。
     触发条件写在规格笔记的「仍未决」第 4 条。
4. **把金样放进 `protocol/`**
   - 最强的理由：本仓已经有 `protocol/fixtures`，看起来"线上东西都归那儿"。
   - 为何被否：`protocol/` 是三端协议向量（帧、封箱、恢复），生成者是连接器自己的实现，
     两边性质不同。金样的生成者是**连接器测试**，就跟连接器测试放一起。
5. **金样顺带收 `repo.info`**
   - 最强的理由：它是最常被手机读的方法之一（能力位 + 方法表）。
   - 为何被否：它的 `methods` 是 `Object.keys(handlers).sort()`（`connector/src/handlers.ts:1519`），
     **加任何方法它都会变**，会为与形状无关的原因常年红。要收它得先归一成"方法条数"，留到第 4 批。

## Consequences

- 收益：漂移在**改连接器的那个提交**里就能被看见（金样 diff + App 回放用例），不用等真机 ——
  这是三次事故里唯一真正缺的一环。
- 收益：`session.list` 的 4 种行（普通 / 子会话 / 冷行 / 完整信封）现在是**一份共享的假行**
  （`connector/tests/support/fixture-handlers.ts`），连接级用例与金样用的是同一份，
  不会再出现"用例喂一种形状、金样另一种"。
- 代价：**引入两个工程之间的测试耦合**。`app/test/wire_shapes_replay_test.dart` 读
  `../connector/tests/fixtures/wire-shapes.json`。先例已存在但方向相反
  （`connector/tests/error-table-parity.test.ts` 读 App 的 `lib/core/errors.dart`），所以不是新范式，是新的方向。
  该文件缺失时**必须 fail**（`skip` 会让门禁静默退化成空跑）。
- 代价：改连接器应答变成了一件"会红两个工程"的事。这是有意的摩擦：
  确认无误后 `UPDATE_WIRE_SHAPES=1` 重生成，并**同一批**改 App 的解码。
- 代价：假行从 1 条涨到 4 条，`connection-methods.test.ts` 里有几处按旧装置写的断言要跟着改
  （`session.list` 的行数、`repo.info.methods` 因为多给了 `models` / `projections` 两个面而多三条）。
  这些是**断言跟着装置走**，不是放宽。
- **未做**：`session.projections` 的 14 个键本轮不解（第 3 批），本轮只是把它的应答收进金样 ——
  它在这里的作用是"证明同一个名字有两种形状"，不是"读它"。

## 判据

- `connector`：**657 → 660**（`tests/wire-shapes.test.ts` 三条：键集合 / 逐字深比较 / 采样确定性）。
  `pnpm exec tsc --noEmit` 0。
- `flutter test`：**1241 → 1243**（`test/wire_shapes_replay_test.dart` 两条：键不缺 / 每条样本是对象且不空）。
- **变异校验**：把金样里 `session.list` 第一行的 `running` 改成字符串 `"true"`
  ⇒ 连接器**恰好 1 条红**（`线上形状与金样逐字一致`），diff 点名 `running: 'true'` vs `false`；
  改回来即绿。这证明金样不是恒真的。
- `node app/tools/verify-rpc-single-caller.mjs` 新增：预算 **39** ⇒ PASS 并静默；
  临时探针（往 `app/lib/data/preview_data.dart` 塞一处 `client.call<`）⇒ FAIL 并逐行报出 40 个位置。
- `verify-tool-paths.mjs`：**23 → 24** 个脚本（新脚本的路径全部相对仓库根，无盘符字面量）。
- `verify-platform-boundary.mjs` **509** 持平。

## 代码入口回指

- `connector/tests/wire-shapes.test.ts`（金样生成与深比较）
- `connector/tests/support/fixture-handlers.ts`（连接级用例与金样共用的一份假行）
- `connector/tests/fixtures/wire-shapes.json`（金样本体）
- `app/test/wire_shapes_replay_test.dart`（App 侧回放：文件缺失即 fail）
- `app/tools/verify-rpc-single-caller.mjs`（"协议知识还有几处漏在 `wire/` 外面"的那个数）
