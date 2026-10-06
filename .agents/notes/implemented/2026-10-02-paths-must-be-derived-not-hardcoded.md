# Agent Note: 工作路径一律从 `import.meta.url` 派生 —— 一次搬盘让 11 个门禁静默全红

Status: implemented（2026-10-02 修复并加门禁；`verify-tool-paths.mjs` 是判据）

## Problem

### 一、环境整体换盘,仓库内的绝对路径引用**静默**失效

这台机器的开发环境从 `C:\sudy` 搬到了 `D:\sudy`（三个只读参考仓库 DSH / Agents-Anywhere /
rikkahub 现在都在 D 盘）。仓库里共有 **22 个文件**写死了 `C:\sudy\...`（`git grep` 实测），它们分两类：

| 类别 | 处数 | 失效后的表现 |
|---|---|---|
| **可执行路径**（12 个 `mock/proto/tools/*.mjs`） | 12 | 浏览器门禁全红 |
| 只读参考路径（`AGENTS.md` / `tools.md` / `docs/**`） | 10 | 查证据时指向一个不存在的目录 |

第一类才是真问题：其中 11 个脚本写的是

```js
const PAGE = process.env.PAGE_URL || 'file:///C:/sudy/myproject/dsh-mobile/mock/proto/index.html'
```

`PAGE_URL` 平时不设，于是默认值生效 → `Page.navigate` 拿到一个**不存在的 file:// URL**。
而**没有任何东西会因此报错**：脚本照常跑完、照常打印一份 JSON，只是断言全红或取到空 DOM。
也就是说这次搬盘之后，**整组浏览器门禁（`verify-proto` / `verify-authz` / `verify-settings` /
`verify-tasks` / `verify-picker`）从"绿"变成"红"，而红的原因是路径而不是代码** ——
最坏的一种红：它看起来像回归。

第二类不报错但更阴：它让"引用 DSH 行为必须给 `packages/...:行号`"这条军规失去可核对性 ——
路径不存在时，后来者无法判断是"代码变了"还是"路径过期了"。

### 二、`relay/node_modules` 被提交进了版本库

`.gitignore` 只忽略了 `connector/node_modules/`，而 relay 同样是独立 pnpm 工程。
结果 673 个文件（约 25 MB 工作区 / 1 MB 压缩后）进了库，且在换盘后**整体变成删除态**
（pnpm 的软链指向已不存在的 C 盘路径），把 `git status` 淹成 389 项。

## Decision

**凡"本仓库内的路径"，一律从 `import.meta.url` 派生，不得硬编码盘符；参考仓库路径只留单一来源。**

1. 11 个 CDP 脚本的 `PAGE` 改成 `new URL('../index.html', import.meta.url).href`
   （`OUT` 同理改用 `fileURLToPath(new URL('../shots', import.meta.url))` —— 顺带修掉
   `OUT = 'mock/proto/shots'` 这个**依赖 cwd** 的写法）。
2. 参考源码路径的单一来源是 `AGENTS.md` §5 与 `tools.md`；`extract-dsh-icons.mjs` 的 DSH 根
   可被 `DSH_SOURCE` 环境变量覆盖，默认值指向当前真实位置。
3. `node_modules/` 一律不入库（`relay/node_modules/` 补进 `.gitignore`，并从索引移除，
   **磁盘文件保留**）。

准入门槛（可机械判定）：

1. `node mock/proto/tools/verify-tool-paths.mjs` —— 扫 `mock/proto/tools/*.mjs`，
   断言**不出现 `file:///` + 盘符的字面量**（硬编码的工作路径必然长这样）。
2. `git check-ignore -v relay/node_modules/ws/package.json` 必须命中 `.gitignore`。
3. 全仓（排除 `node_modules` / `shots` / `backup`，以及**本笔记与门禁自身**——它们要写出这个字符串才能描述规则）
   grep `C:\sudy` / `C:/sudy` → 0 命中。

## Alternatives considered

1. **把 11 个脚本里的 `C:` 直接改成 `D:`**
   - 最强的理由：一处一个字符，改动最小、最容易 review，且今天立刻能用。
   - 为何被否：它把"这台机器当前把仓库放在哪个盘"固化进了 11 个文件。下一次搬盘（或换台机器 clone
     到别的目录）会**原样再坏一遍**，而且同样是静默的。这正是这次踩的坑本身，不是解法。
2. **让所有脚本从 `process.cwd()` 拼相对路径**
   - 最强的理由：不依赖 `import.meta.url`，读起来直观（`mock/proto/index.html`）。
   - 为何被否：它把"必须从仓库根运行"变成隐式前置条件，而门禁文档里从没写过这条；
     从 `tools/` 目录里跑、或在 IDE 里以别的 cwd 启动都会静默取到错路径 ——
     与硬编码盘符是同一类失败（**错得没有声音**），只是触发条件换了一个。
3. **引入 `.env` / 配置文件集中管理路径**
   - 最强的理由：所有可配项一处可见，改环境只动一个文件。
   - 为何被否：为一个"本可自动推导"的值引入一份必须手工维护、且**缺失时行为未定义**的配置 ——
     脚本要额外处理"没配"的分支，而那分支又会变成新的静默降级口子。
     `import.meta.url` 是**无配置、无分支、恒定正确**的那条路（`PAGE_URL` 覆盖能力原样保留，
     它是给"驱动一个别处部署的原型"用的，不是给本仓自用兜底的）。
4. **只改代码、不删 `relay/node_modules` 的入库**
   - 最强的理由：与本次修复无关的仓库卫生问题，混进来会让 diff 从 26 个文件变成 699 项，
     淹没真正的改动。
   - 为何被否：它**正是让 diff 变成 389 项的原因** —— 不处理它，这次提交的 `git status`
     就没法看（AGENTS.md §6 明确要求"提交前必看完整清单，重点是意外的文件"）。
     先把它移出索引，剩下的 26 项才是可 review 的。

## Consequences

- 收益：浏览器门禁重新可用（实测 `verify-proto` exit 0、`verify-authz` 18/18、
  `verify-settings` 27/27、`verify-tasks` 53/53、`verify-picker` 通过）；工作路径从此**与盘符和
  工作目录无关**；`OUT` 不再依赖 cwd；`git status` 回到可读规模（699 → 26 项）；
  参考仓库路径有了单一来源。
- 代价：脚本里多一行 `new URL(...)`，比裸字符串长一点；**`relay/` 现在必须先 `pnpm install`
  才能跑测试**（`ws` 是运行时依赖，`tests/server.test.ts` 起真服务器）—— 这条以前被
  `tools.md` 写成"不需要安装即可跑测试"，是错的，本次一并改正。
- 代价：这次修复**本身没有测试能证明"下次搬盘不会再坏"** —— `verify-tool-paths.mjs` 只能拦
  "又写死了盘符"，拦不住"用了一个相对 cwd 的路径"（替代方案 2 那种）。
  后者的防线是 code review，不是门禁。
- 遗留：`extract-dsh-icons.mjs` 的 `DSH_SOURCE` 默认值仍是**这台机器的绝对路径** ——
  它无法从 `import.meta.url` 推导（参考仓库在别的仓里）。这是有意的：该脚本只在 DSH 升级后
  手工重跑一次，且现在有环境变量可覆盖，失败时会明确报"读不到文件"而不是静默产出空图标集。
