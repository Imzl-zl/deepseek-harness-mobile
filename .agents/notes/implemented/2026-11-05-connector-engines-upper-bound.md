# Agent Note: `engines.dsh` 的上界必须写成 `<X.Y.Z-0`

Status: implemented

## Problem

`connector/package.json` 原来写 `engines.dsh: ">=0.2.1-rc.5 <0.2.2"`，意图是「只支持 0.2.1 这条线」（`2026-10-31-plugin-engines-dsh.md` 明说 0.2.2-alpha.* 没测过、不 claim）。但 DSH 的判定是 `semver.satisfies(runtime, range, { includePrerelease: true })`（`packages/boot/app-boot/src/plugin-compatibility.ts:51-53`）。开着 `includePrerelease` 时 `0.2.2-alpha.2 < 0.2.2` 成立，于是这条范围**放行整条 0.2.2 预发布线**：`0.2.2-alpha.2`、`0.2.2-alpha.3`、`0.2.2-rc.1` 全部判兼容，只有 `0.2.2` 正式版才被拒。

行为与意图正好相反：破坏最密集的预发布区间被放行，等 DSH 发正式版反而把插件踢掉。DSH 仓库 `docs/upgrade-guide/v0.2.2-alpha.2/` 下那 21 条破坏正落在被放行的区间里。

## Decision

`engines.dsh` 写成 `">=0.2.1-rc.5 <0.2.2-0"`。

`0.2.2-0` 是 0.2.2 全部预发布的下界；排他上界把它连同其后每一个预发布、以及正式版一起挡在门外，而 `0.2.1-rc.5` / `0.2.1-rc.9` / `0.2.1` 照常放行。

准入门槛（`connector/tests/manifest-compat.test.ts` 机械判定）：

1. 全部 `@deepseek-ai/dsh*` 依赖钉同一个精确版本；不统一即失败。
2. `semver.minVersion(engines.dsh)` 必须等于那个版本——下界写得更低等于 claim 一个没测过的旧版本。
3. 下一条线（`patch + 1`）的 `-0` / `-alpha.0` / `-rc.1` 与正式版必须**全部**被拒；探针本身先断言是合法版本，非法探针会让断言空转。

## Alternatives considered

1. **保持 `<0.2.2`，什么都不改**
   - 最强的理由：字面上就是「小于 0.2.2」，和意图一致，不用动任何东西，也不会有人问 `-0` 是什么。
   - 为何被否：`includePrerelease` 下它不等于「小于 0.2.2 的正式版」，实测放行三个 0.2.2 预发布。留着等于把「没测过就不 claim」这条规则作废，而且症状是静默加载，不是报错。

2. **`^0.2.1-rc.5`（等价 `>=0.2.1-rc.5 <0.3.0`）**
   - 最强的理由：最省事，宿主小版本升级不用跟，一次声明管很久。
   - 为何被否：2026-10-31 已否过，理由不变——claim 了没测过的线。这次只是把同一个理由贯彻到预发布，不是新政策。

3. **上界写 `<=0.2.1`**
   - 最强的理由：不依赖 `-0` 这种不直观的写法，读起来就是「到 0.2.1 为止」。
   - 为何被否：0.2.1 正式版未必发布；而且它表达的是「包含 0.2.1」，与「只认 0.2.1 这条线」不是一回事。`-0` 直接表达「这条线的全部预发布都排除」。

4. **不改范围，改成每次宿主发预发布就发一个新版本**
   - 最强的理由：不用研究 semver 边界，跟着发就行。
   - 为何被否：把「DSH 发 rc」变成「我们必须跟着发版」，而用户装到的仍是旧版、DSH 只会静默跳过；这正是 2026-10-31 想甩掉的负担。

## Consequences

- 收益：声明范围与实际验证过的版本重新对齐。DSH 升到 0.2.2 任一预发布时，插件被**明确拒绝**并给出 `engines.dsh` 原因，而不是装上去静默跑坏。
- 代价：宿主一进 0.2.2 线，手机侧通道直接不可用（bundle 被跳过），直到我们测完 0.2.2 并发新版本。用户急用只能走 `dsh plugin allow-version` 的精确版本豁免——那是带风险确认的正规口子，不是绕过。
- 代价：`<X.Y.Z-0` 看着像笔误，后来者很可能「顺手修正」成 `<X.Y.Z`。所以用例与本文同时存在；改之前先看 `connector/tests/manifest-compat.test.ts` 的失败信息。
- 代价：新增 devDependency `semver@7.8.5`（与 DSH 自用同一版），只给这条用例用；它不带类型声明，测试里用 `createRequire` 载入并手写三个函数签名——手写的签名可能与真实 API 漂移，但用到的只有 `satisfies` / `minVersion` / `parse`。
- 文档：`docs/subsystems/remote-channel.md` 与 `docs/subsystems/connector-and-relay.md` 里「兼容性只看 `peerDependencies`」「写 `engines.dsh` 没有任何效果」两处旧说法改成现行规则；后者手抄的整份 `package.json` 删掉，改成指向真文件加五条不变量（手抄版从版本号到依赖条数都已落后）。
