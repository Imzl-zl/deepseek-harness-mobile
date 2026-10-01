# Agent Note: `relay/` 的骨架 —— 直接用 Node 的类型剥离，不引入构建步骤

Status: implemented（`relay/package.json` + `relay/tsconfig.json`；`ws` 依赖与安装随网络层落地）

## Problem

前五轮里，中转的测试一直靠**借连接器的工具链**跑（`cd connector && pnpm exec tsx --test ../relay/tests/...`）。
那是权宜之计，而它有两个坏处：一是中转的测试能不能跑取决于另一个工程装没装依赖；
二是"两套工程共用一个 node_modules"会让依赖边界悄悄消失（将来其中一边升级工具链，另一边跟着变）。

## Decision

**中转不引入构建步骤**：它自己的导入用 `.ts` 结尾，直接在 Node 的**类型剥离**下运行。

- 本机是 Node **24.13**，类型剥离是内建能力（23.6 起不再需要实验开关）；
- 于是 `relay/package.json` 的 `test` 就是 `node --test`（Node 自带的测试运行器会发现
  `tests/*.test.ts`），**零运行时依赖、零构建**；
- 代价是导入必须写 `.ts`（Node 的类型剥离**不做** `.js` → `.ts` 的映射，
  这一点是实测出来的：写 `.js` 时报 `ERR_MODULE_NOT_FOUND`）。这也正是连接器那套
  （`.js` 结尾 + tsdown 打包）**不能**直接照搬的原因：两者的运行时不同。
- `tsconfig.json` 因此要 `allowImportingTsExtensions`（它要求 `noEmit` ✓ 我们本来就不产出 JS）。

**为什么这与连接器不同，值得写下来**：连接器是**插件**，产物要被 DSH 加载（所以有 tsdown 构建、
`peerDependencies` 指向 DSH 包）；中转是**独立服务**，由用户自己起（`node src/main.ts` 即可），
没有任何东西要求它是 JS。两个工程用两种方式跑，正是它们职责不同的表现，而不是不一致。

准入门槛（可机械判定）：

1. `cd relay && node --test` → 33 条全绿（**不借任何外部工具链**）。
2. `tsc --noEmit -p relay/tsconfig.json` → 0 错（本轮用连接器的 tsc 与 `@types/node` 验证；
   `relay/` 自己 `pnpm install` 之后应当用自己的）。

## Alternatives considered

1. 照抄连接器：`tsdown` 构建 + `.js` 结尾 + `tsx` 跑测试
   - 最强的理由：两个工程一套做法，读起来一致，将来若要发布产物也现成。
   - 为何被否：中转**没有产物消费者**（它是被用户直接起的服务），为一个不存在的需求引入构建步骤，
     换来的是"改一行要重新构建"的摩擦，以及多一个必须与源码同步的产物目录。
2. 继续借连接器的工具链跑中转测试
   - 最强的理由：零配置，现在就能跑。
   - 为何被否：依赖边界会消失（上面 Problem 里的第二点），而且中转的测试会在
     连接器没装依赖时直接失败 —— 那是"两个组件耦合在开发环境里"的味道。
3. 让中转也用 `.js` 结尾 + 一个 tsx 依赖（保留 Node 直跑，不写构建）
   - 最强的理由：导入风格与连接器一致。
   - 为何被否：那要求 `.js` 真的存在或由别的工具重写，于是又回到"需要一个重写工具"（就是 tsx）。
     而 `.ts` 结尾 + 纯 `node` 是**最少活动部件**的那条路。

## Consequences

- 收益：中转的测试与类型检查自足；`relay/` 有了自己的 `package.json`（含 `engines` 说明它依赖
  Node ≥ 22.6 的类型剥离）。依赖边界重新清晰：中转不依赖连接器，连接器不依赖中转。
- 代价：中转的导入风格与连接器不同（`.ts` vs `.js`）—— 已在上面写清理由，避免后来人"顺手统一"。
- **仍未做（下一轮）**：
  1. `relay/` 的依赖安装（`pnpm install`，需要网络）—— `ws` 在中转是**运行时依赖**
     （它要接受连接），随 `http`/`ws` 接线一起加，加了就当场验证。
  2. `http` + `ws` 接线：两个入口（连接器校验令牌 / 设备消费票）+ `POST /ws-ticket` 的真实服务器。
  3. 令牌摘要表（§12.2 的 SQL 面），即 `authenticate` 端口的真实实现。
  4. 电脑侧出码时调 `/pairing/register`。
