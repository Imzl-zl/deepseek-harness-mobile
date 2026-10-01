# Agent Note: 无主事件有两种形状 —— 补适配器测试时抓到的订阅过滤缺陷

Status: implemented

## Problem

`src/dsh/` 下四份适配器（`sessions` / `jobs` / `subagents` / `settings`）此前**零测试**：
`layering.test.ts` 只保证它们对着源码写过行号引用，不保证行为对。补测试时（先读类型、再写断言），
在 `jobs.ts` 的订阅过滤里读出一个真缺陷：

```ts
// 修改前
if (event.type !== 'output' && 'job' in event && event.job.owner === undefined) return
```

`JobEvent` 是联合，**无主有两种形状**（`packages/jobs/jobs/src/types.ts:200-226`）：

- `registered` / `progress` / `stopping` / `removed` / `settled` 把任务放在 `event.job` 里 → `job.owner` 缺键即无主；
- `output` 把 `owner` 放在**事件自己**身上（`{ id, owner?, total }`）→ 上面那个条件对它**恒为真**。

于是无主任务的 `output` 事件被放行到**每一个**订阅了该会话的手机上，
而手机在清单里看不到那个任务（`listOwnedBy` 已经排掉了无主）——
表现是"收到一段没有出处、也不属于任何会话的输出"，而电脑侧一切正常。

## Decision

**无主判定统一成一条**："该事件承载归属的那个字段缺键即无主"；
`jobs.ts` 里做成一个小判断（`output` 看事件自己的 `owner`，其余看 `job.owner`），
并且这一条只写一次、由测试同时钉住两种形状。

顺带把这一轮的范围定成**给三份适配器补测试**（`jobs` / `subagents` / `settings`），
并把"装配之前必须先有测试"从上一轮的声明变成已执行的事实。

准入门槛（可机械判定）：

1. 无主的 `progress` / `settled` / `output` 三种事件都不进订阅回调；有主的三种都进。
2. `listOwnedBy` 排掉无主任务，且**必须传 caller**（不传只返回无主，不是全集）。
3. `readOutput` 走 `readAt(id, from, caller)`，`caller` 在**第三位**，`lossy` 原样上报。
4. `subagents.descendants` 拍平联合：诊断行**不含** `activity` / `mode` / `label` / `hasChildren`。
5. `settings.snapshot` 必须传 `redactSecrets: true`；`setField` **绝不**走 `replace`。

## Alternatives considered

1. 保持原样（`output` 事件放行）
   - 最强的理由：保守放行比误杀好 —— 客户端可能正通过别的方式看一个无主任务，
     少给一段输出比多给一段更难查。
   - 为何被否：与本层自己的另一条规定**自相矛盾** —— `listOwnedBy` 已经明确"无主任务不算属于本会话"，
     于是手机清单里没有它、流里却来它的输出，客户端只能丢弃或造一个幽灵任务。
     两条规则必须一致：清单不认的东西，流里也不该推。
2. 改成按"收到的会话 id"比对（`event.owner === dshSessionId`）
   - 最强的理由：更精确，连"注册器的过滤器失准"也一并兜住。
   - 为何被否：注册器**已经**按 `{ owner: S }` 过滤过一遍，这一层只是补"无主会被并进来"的那个洞；
     而 `owner` 在不同事件里的**形状不一样**（对象 / 裸值 / 缺键），逐一比对等于把同一件事写两遍，
     下次 DSH 加事件类型时又会漏一路 —— 正是这次缺陷的成因。统一成"承载归属的字段缺键即无主"只有一处判据。
3. 让 DSH 的注册器干脆不返回无主事件（改宿主）
   - 最强的理由：从源头消灭这个洞，插件不必再过滤。
   - 为何被否：那是宿主行为（`jobs-local/src/index.ts:308` 的并集语义是它有意为之，
   `jobs-local/src/events.ts:85` 的短路也是），插件不改 DSH。记录在案即可。

## Consequences

- 收益：无主任务的输出不再插进所有会话的流；三份适配器第一次有了测试（共 11 条），
  且每一条都针对"写错不会报错"的具体形状（并集语义、参数位次、联合拍平、脱敏开关、只走 mutate）。
  `src/dsh/` 下的测试覆盖率从 2/6 变成 5/6（只差 `interactions.ts`，它是注册器接线，已有 e2e 之外的覆盖缺口待补）。
- 代价：`jobs.ts` 的 subscribe 多一个小判断；契约文档层面无改动（§7 本来就要求"按 owner 过滤"）。
- **仍未做**：方法的装配（`job.list` / `job.follow` 等还没接 handler）、`interactions.ts` 的测试缺口。

## 一条测试方法论（这次是变异校验自己的保真度）

给"联合拍平"写变异时，第一次的变异把诊断行**原样展开**（`{ ...entry, parentId, depth }`）——
**测试全绿**。追下去发现那不是变异：诊断行本来就只带 `{ kind, id, parentId, depth, reason }`，
展开它得到的字段与显式构造完全一样，语义没变，当然不该红。
换成**真实的失效形状**（去掉 `kind === 'diagnostic'` 分支，让诊断行走 child 分支、
带上 `undefined` 的 `activity`/`mode`）之后，同一条用例立刻命中。

教训：**变异必须改变语义，而不只是改变写法**。"看起来改了一处"不等于"行为变了"——
否则会得出"测试覆盖不到"的错误结论（这一轮与上一轮的替身不忠实，是同一类误判的两种形态）。
