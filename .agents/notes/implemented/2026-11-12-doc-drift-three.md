# Agent Note: 三处文档/代码漂移 —— 逐条判定留、删、改

Status: implemented

## Problem

`memory.md` 与两份笔记里记着三处"文档与代码说的是两件事"。它们都不是"少写一句文档"，
而是同一个事实有两处表达（一处是文档/清单，一处是实现），而**没有东西会把它们对上**：

| # | 漂移 | 证据 |
|---|---|---|
| 1 | `docs/subsystems/connector-and-relay.md` §1.2 写「`dsh/` 不 import `transport/`」，而 `connector/src/dsh/interaction-client.ts:63` import 了 `transport/backoff.js` | 这条规则**从来没被机械执行过**：`tests/layering.test.ts` 只钉 `protocol/` 零 DSH 依赖、`dsh/` 带源码引用、服务键登记 |
| 2 | `plugin.installStatus` 有 4 键（`unknown`）与 8 键（`done`）两种形态，金样只收了一种 | 金样 `plugin.installStatus` 只有 `done` 一条；根因是**替身在撒谎**（见下） |
| 3 | `caps.approval`（`connector/src/dsh/caps.ts` 的 `readCaps`）报了，全仓没有读者 | `app/lib/wire/rpc/repo.dart` 只解 `references`/`files`/`changes`/`plugins`/`jobs`；连接器侧没有任何挂载判据读它 |

## Decision

### 1. 分层规则收窄成"目标必须是纯叶子"，并加机械判据

`backoff.ts` 是**零依赖的纯计时器**（`1s→2s→…→30s`，抖动注入），`transport/connection.ts`
与 `dsh/interaction-client.ts` 用的是**同一个事实**（"多久重连一次"）—— 复制一份才是两处表达。
所以 import 是正当的，**错的是那条规则**：它按**目录名**判，而害处是**耦合**（适配层间接认识
"socket 怎么开"），纯叶子不产生耦合。

- 文档 §1.2 改成：`dsh/` 可以引 `transport/`，**但目标模块自己不许有依赖**；带依赖的
  （`connection` / `relay-link` / `listener` …）一次都不许引。顺带点明这条老规则
  "从来没被机械执行过"，免得下次又被当成"已经有人守着"。
- `tests/layering.test.ts` 加一条真实扫描 + **4 条自检样本**：纯叶子放过、带依赖拦下、
  注释里的 `from '…'` 不算依赖、路径写错也拦下。
- 变异校验：给 `transport/backoff.ts` 加一行 `import { readFileSync } from 'node:fs'`
  ⇒ **1/84 项红**，红的话是 `dsh/interaction-client.ts 引了 transport/backoff.ts（它自己有依赖，不是纯叶子）`。

### 2. 两种形态都是真值：它是 `status` 上的判别联合；根因是替身只会一种

`unknown`（这一代插件没有这个 requestId 的记录）**只回 4 个键**：没有任务就没有
`kind` / `phase`，编一个就是假值。所以两种形态不是"新老兼容"，是**同一方法的两个分支**。

问题是金样只收了一种，而原因是 `tests/support/fixture-handlers.ts` 的 `pluginInstall.status`
**无差别地回 `done`** —— 替身不忠实，于是 `unknown` 那条路线上没有任何形状断言。
（同 `tools.md` 里㉛那条教训："测并发的替身必须保留真实介质的时序特征"。）

- 替身改成记着自己起过哪些 `requestId`，没起过的回 `unknown` 的 4 键形状（与
  `dsh/plugin-install.ts` 的 `status()` 逐键同形）。
- 金样加第二条样本（`requestId: 'plug-404'`）—— 再生成时**其它方法的形状一个字节都没动**
  （`git diff` 只有 +6 行）；`repo.info` 的 `methods` 归一照旧生效。
- App 侧只解第一条样本是不够的（只钉一种形态），所以 `wire_shapes_replay_test.dart` 加了
  `_sampleAt(...)` 并解第二条：`status == 'unknown'`、`kind`/`phase`/`log` 皆空、
  **金样里不许有 `kind` 键**。契约 §7 那一行也写明判别联合（`unknown` ⇒ 4 键）。
- 没有变异校验：这一条改的是"样本有没有覆盖那条分支"，`unknown` 那条断言本身就是判据
  （删掉替身的 `started` 分支 ⇒ 金样回 `done` ⇒ 新断言立刻红）。

### 3. `caps.approval` 留着，并把理由写在字段上

它不是"留给未来的字段"，而是**现在就有读者**——只不过读者**不是代码，是排错的人**：

- `/api/dsh-mobile/status` 与 `repo.info` 都照报整个 `caps`，`tools.md` 的验收判据就写着
  读 `/status` 的 `caps.direct`；
- 上一批把 `interaction.respond` 改成按 **`approval` 或 `userQuestions`** 至少一个在来挂
  （`implemented/2026-11-12-caps-settlement.md`）。于是"审批卡答不掉"这种现场，
  `caps.approval` 与 `caps.questions` 一起就指出缺的是哪半边 —— 删掉它等于把那个现场的唯一
  可读事实抹了。

所以：`Caps.approval` 的文档注释写清"不决定任何方法挂不挂，留着是因为……"，
App 侧 `repo.dart` 的文件头补一句"`caps` 里手机不读的那七个键为什么不删、不声明"。

**没有删**，因此**没有改线上形状**：金样与契约 §7 的 `caps` 行都不用动。

## 准入判据

| 判据 | 结果 |
|---|---|
| `cd connector; pnpm exec tsc --noEmit` | 0 |
| `cd connector; pnpm build` | 产物 2 个文件（`lib/index.js` / `lib/index.d.ts`） |
| `cd connector; pnpm test` | **854 项全绿**（fixtures 断言 **454** / 向量 **49** 与参考侧相等） |
| `cd connector; pnpm exec tsx --test tests/layering.test.ts` | 1 项，84 条检查（自检 4 条新增样本在内） |
| 金样重生成 | `git diff` 只有 `plugin.installStatus` **+6 行**（`unknown` 那条） |
| `cd app; flutter test test/wire_shapes_replay_test.dart` | 58 项全绿（新增 `unknown` 两条断言） |
| `cd app; dart analyze --fatal-infos lib test integration_test` + `dart format` | 各 0 |

## Alternatives considered

1. **把 `transport/backoff.ts` 挪到 `src/`（或新建 `src/shared/`），让老规则成真**
   - 最强的理由：不给规则加"纯叶子"这个例外，一条规则一句话。
   - 为何被否：退避**本来就是传输策略**（`transport/index.ts` 的表里写着它），挪走是为了
     迁就一条按目录名判的规则；而且为一个文件新建一个目录是"用结构换掉一句解释"。
     更重要的是：真问题是耦合，纯叶子没有耦合 —— **规则该跟着事实走，不是事实跟着规则走**。
2. **把 `backoff` 从 `dsh/interaction-client.ts` 里摘掉，改成注入（deps.backoff 已有）**
   - 最强的理由：那样 `dsh/` 就一行 `transport/` 的 import 都没有了。
   - 为何被否：`deps.backoff` 是给**测试注入确定值**用的（随机数可定）。生产里让装配层传
     一个退避器进来，等于把"多久重连一次"这个事实拆到两个文件；而重连策略在同一个文件里
     读得完才是它今天的样子。
3. **`plugin.installStatus` 统一成一种形状**（要么恒带 `kind`/`phase`，要么恒不带）
   - 最强的理由：一个方法一种形状，客户端好写。
   - 为何被否：`unknown` 时没有任务，`kind`/`phase` 只能编 —— 而"编一个值"正是本仓
     `AGENTS.md` 明令禁止的（不发明值）。另一种（恒不带）会让 `running` 的进度卡丢掉
     "正在装/正在卸"这一行，那是真实信息。判别联合是唯一不撒谎的选择。
4. **删掉 `caps.approval`（连同金样与契约 §7）**
   - 最强的理由：没有代码读者，删了少一处漂移面。
   - 为何被否：见上 —— 它的读者是排错的人，且上一批的挂载判据正好让它变成"缺哪半边"的
     证据。真要做，得先有第二个判据替代它（比如让 `/status` 直接报 `interaction.respond`
     挂没挂），那是另一个决定面，不该借"清漂移"顺手做掉。
5. **把 `caps` 里手机不读的七个键全部删掉，只报有人读的**
   - 最强的理由：报告面与消费面严格相等，"报了就一定有人读"。
   - 为何被否：`caps` 的用途之一是**排错**（`tools.md` 的验收就靠读 `/status` 的
     `caps.direct`）。把"这台电脑有什么服务"删成"手机要用的那五个"，排错时就得去翻宿主日志。
     **自报面与门控面是两件事**，只是在多数键上恰好重合。

## Consequences

- 收益：§1.2 那条规则第一次**有牙**（84 条检查里的真扫描 + 4 条自检）。它不会因为
  "有人下次顺手 import 一个 `connection.js`"而静默失效。
- 收益：`plugin.installStatus` 的 `unknown` 分支第一次进入金样与 App 回放；替身不再比真实现
  "更能干"，这一点和 `tools.md` 的㉛ / ㊲ 两条教训是同一类。
- 代价：`layering.test.ts` 多了一个"读目标文件"的检查（跨文件），比原来的纯文本规则复杂一点；
  它自带的 4 条自检样本是它的代价与保险。
- 代价：`Caps.approval` 的注释长了 7 行，替换掉原来的一行「审批接管。」。这是刻意的：
  一个**看起来该有人读**的字段，必须自己写清"为什么留着"，否则下一个人还会来问一次。
- 未做：`caps` 里另外六个手机不读的键（`questions`/`subagents`/`sessions`/`storage`/
  `settings`/`credentials`）**没有逐个加注释**。它们没有"被人问过三次"的记录，
  统一说明放在 App 侧 `repo.dart` 的文件头就够了 —— 一个事实一处表达，不必七个字段七段话。
- 未做：`transport/startup.ts` 引 `dsh/relay-token.ts`（读连接器令牌）这条**反方向**的依赖
  没有加规则。它是装配层读凭据的正当路径，而 §1.2 的分层规则现在只约束 `dsh/ → transport/`
  这一侧；要给反向也立判据，得先说清"装配层能认识哪些适配层模块"，那是另一个决定面。
