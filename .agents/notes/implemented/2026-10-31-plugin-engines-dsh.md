# Agent Note: 插件兼容性改由 `engines.dsh` 声明

Status: implemented

## Problem

宿主升到 DSH `0.2.1-rc.5` 后，隔离实例启动时报：

```
skipping profile bundle "@dsh-mobile/connector": Error: Plugin dsh-mobile-connector@0.1.3
is incompatible with dsh 0.2.1-rc.5: requirements {"@deepseek-ai/dsh-typert-protocol":"0.2.1-rc.3"}
```

原因是我们把 `@deepseek-ai/dsh-typert-protocol` 的**精确版本**写在 `peerDependencies` 里。
rc.5 的判定是：**包里没有 `engines.dsh` 时，逐个 `@deepseek-ai/dsh*` peer 都必须匹配
宿主版本**（`packages/boot/app-boot/src/plugin-compatibility.ts:55-72`，`satisfies` 用
`includePrerelease: true`）。于是"宿主每升一个 rc，插件就被跳过一次"，而每次都要发新版本
才能恢复——这条路不能长期用。

## Decision

**声明 `engines.dsh: ">=0.2.1-rc.5 <0.2.2"`，让兼容性由一条显式范围决定。**

- 有 `engines.dsh` 时，peer 里的 `@deepseek-ai/dsh*` **不再参与判定**（同一处源码
  `:57-61`）。范围表达"我们支持 0.2.1 这条线（含其后的 rc）"，而不是"只支持某一个 rc"。
- 上界写 `<0.2.2` 而不是 `<0.3.0`：`0.2.2-alpha.*` 已在 npm 上，我们没测过；claim 支持
  一条没验证过的线，代价是用户拿到一个"装上了但可能崩"的插件。
- `peerDependencies` 与 `devDependencies` 全部对齐 `0.2.1-rc.5`：类型检查对着宿主真实
  版本跑，而不是对着一个旧版本"看起来能编"。
- 不改代码逻辑：这次只有清单与依赖版本变化，`tsc` 0、`pnpm build` 通过、`pnpm test`
  **773/773**。

## Alternatives considered

1. **继续用 peer 精确版本，每升级一次就发一个补丁**
   - 能过，但把"宿主发 rc"变成"我们必须跟着发版"；用户装到的是过期插件，而 DSH 只是
     **静默跳过**，症状是"插件没生效"，很难追。
2. **`engines.dsh: "^0.2.1-rc.5"`（等价 `>=0.2.1-rc.5 <0.3.0`）**
   - 更省事，但把 `0.2.2-alpha.*` 也算作支持；没测过就不 claim。
3. **删掉 `engines.dsh`，只留 peer**
   - 就是现状；已经证明会被 rc 升级打断。

## Consequences

- 宿主下次进 `0.2.2` 线时，这个插件会被判不兼容——这是**有意**的：届时先跑
  `pnpm test`（宿主 API 可能已变），再把上界抬高，而不是让它悄悄跑。
- 出问题时的临时口子：`dsh plugin allow-version dsh-mobile-connector@<ver> --dsh-version <exact> --accept-risk`。
- 文档同步：`tools.md` 的兼容性坑点、`docs/design-and-tech-plan.md` 的工程形态、
  `docs/channel-review-notes.md` 的判定表都改成"先看 `engines.dsh`"，避免两处说法打架。
- 发布：`dsh-mobile-connector@0.1.4`。
