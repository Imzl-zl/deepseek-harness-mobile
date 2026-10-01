# Agent Note: 跨工程 e2e 的第一段 —— 中转与连接器之间那条传输缝

Status: implemented（`tests/relay-transport-seam.test.ts` + `tsconfig.e2e.json`；三方 e2e 见"仍未做"）

## Problem

第 38 轮给连接器的拨号加上了 `Authorization` 头（实测 undici 扩展才敢用的写法），
但**没有任何测试碰过它**：既有用例里 `dial` 都是桩，而那条写法一旦失效，
表现是"服务端看不到 authorization"→ 升级被拒 → 连接一直重连。

而这条缝**跨越两个工程**（`relay/` 起真服务器、`connector/` 用真连接层拨号），
既有测试各自只看自己那半边。

## Decision

新增跨工程 e2e 的第一段（2 条用例），覆盖这条缝上的三件事：

1. **令牌走升级头**：连接器的真 `dial`（与产品同一个写法）指向中转的 `/ws/connector`；
2. **中转的路径分流与 `authenticate`**：连上之后 `core.stats.connectors === 1`；
3. **连接层进入握手态**（说明升级真的成功了，而不是"连上又立刻被拒"），
   并且断开是**双向收口**（`connection.stop()` 之后中转的在线集合也要清掉）。

另一条用例走**失败路径**：令牌不对 → 中转 401（一条都没接受）→ 连接层进入自己的重连退避
（`backoff`），而不是停在一个假的"已连接"状态。

**类型检查怎么摆**：这条用例用 `.ts` 后缀导入 `relay/` 的源码（relay 是"直接在 Node 上跑 TS"，
导入写 `.ts`，见第 31 轮），而那只在 `allowImportingTsExtensions` 下合法。
选择是**不开在主配置里**：开了之后 `src/` 里也能写 `.ts` 后缀，而连接器的构建走 tsdown
（不认那个后缀），那是一处静默的坑。于是新增 `tsconfig.e2e.json`（extends 主配置、
开那个开关、把 `../relay/src` 一起纳入），主配置把这一条用例 exclude。
代价是多一个配置文件与一条 `typecheck:e2e` 脚本；收益是 `src/` 的规则不被放松。

准入门槛（可机械判定）：`pnpm exec tsc --noEmit`（主配置）+ `tsc --noEmit -p tsconfig.e2e.json`
（跨工程）都 0 错；2 条用例全绿。

## Alternatives considered

1. 在主 `tsconfig.json` 里开 `allowImportingTsExtensions`
   - 最强的理由：少一个配置文件，`pnpm exec tsc --noEmit` 一条就够。
   - 为何被否：它同时对 `src/` 生效 —— 有人写了 `import './x.ts'`，类型检查会通过，
     而 tsdown 构建会失败（或更糟：产物里留着 `.ts` 说明符）。用一个文件换掉一处静默坑，值得。
2. 把这条 e2e 放进 `relay/` 工程（relay 的配置本来就允许 `.ts` 后缀）
   - 最强的理由：不需要新配置。
   - 为何被否：它会要求 `relay/` 能解析 `@deepseek-ai/*`（那是连接器的 peer/dev 依赖），
     而中转**不依赖 DSH** 正是它的架构性质之一。方向反了。
3. 让 e2e 把中转当**子进程**起（`node relay/src/main.ts`）再走 socket
   - 最强的理由：更接近生产（中转本来就是一个独立进程），而且完全避免跨工程 import。
   - 为何被否（**暂时**）：它需要 `relay/src/main.ts`（读端口/令牌来源的入口），而那个还没有。
     这是下一步更好的形态：等它写出来，这条 e2e 应当改成子进程跑 —— 那时
     `tsconfig.e2e.json` 也可以撤掉。**记在这里，免得忘了它是过渡方案。**

## Consequences

- 收益：中转与连接器之间那条缝有了会红的证据（升级鉴权、在线集合、双向收口、失败路径）。
  它也是三方 e2e（配对 → 握手 → 发一句）的地基 —— 那条缺的只是"另一侧有人说话"。
- 代价：一个额外的 tsconfig + 一条脚本；跨工程 import 让两个工程在**测试**上耦合（生产上不耦合）。
- **仍未做（下一步）**：
  1. 三方 e2e：中转 + 连接器（用 fixture 的连接层 + 手机替身）跑通"配对 → 握手 → 发一句"；
  2. `relay/src/main.ts`（中转的可运行入口）—— 有了它，这条 seam e2e 可以改成子进程形态；
  3. 手机端 Dart 客户端；每连接状态那个岔口。
