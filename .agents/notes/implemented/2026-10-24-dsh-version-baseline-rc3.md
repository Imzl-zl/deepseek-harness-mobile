# Agent Note: 依赖基线对齐到 DSH `0.2.1-rc.3` + `cordis 4.0.5`

Status: implemented

## Problem

用户升级了 DSH 之后问"要不要改"。查出来的不是"版本号新了一点"，而是**真错配**：

- 你机器上跑的运行时（`D:\soft\DeepSeek Harness\resources\app.asar\dsh\node_modules`）：
  `@deepseek-ai/cordis` = **4.0.5**、`dsh-*` = **0.2.1-rc.3**、`schemastery` = 3.18.5
- 我们 `connector/package.json` 声明的：`cordis` = **4.0.4**、`dsh-*` = **0.2.1-rc.2**

`cordis` 是插件框架本体：宿主一份、连接器目录里再一份，就是**两份 `Context`/`Service` 实现**。
它今天没炸（真机全部功能在 rc.3 宿主上跑通），但这是 Cordis 插件的典型事故源
（`ctx.get` 拿到的是别人家的 Service、`effect` 顺序失真、`instanceof` 判不过），
属于"能不出事但迟早出事"的那类漂移。

## Decision

把所有 `@deepseek-ai/*` 的 peer/dev 版本对齐到**宿主实际安装的版本**：

| 包 | 之前 | 现在 |
|---|---|---|
| `@deepseek-ai/cordis` | 4.0.4 | **4.0.5** |
| `dsh-typert-protocol` | 0.2.1-rc.2 | **0.2.1-rc.3** |
| 其余 11 个 `dsh-*` devDep | 0.2.1-rc.2 | **0.2.1-rc.3** |
| `schemastery` | 3.18.5 | 3.18.5（本来就对） |

**判据不是"看 changelog 猜"，是看宿主里装的是什么**（用 `ELECTRON_RUN_AS_NODE=1` 让 Electron 当 node
去 `require` app.asar 里的 `package.json`，一行版本号一个）。这也是以后每次 DSH 升级的固定动作。

## Alternatives considered

1. **不动**（"反正现在跑得好好的"）—— 最强理由：真机上所有功能确实全通，改版本反而引入风险。
   被否：两份 cordis 的失败是**非确定性的**（取决于哪个先被 `require`、插件加载顺序），
   而且下次 DSH 再升级时"rc.2 对着 rc.4"只会更难排查。现在升是**零成本**（见下），等出事再升是**高成本**。
2. **只升 `cordis`、不升 `dsh-*`** —— 最强理由：`cordis` 才是两份实现的那个包，其它是普通依赖。
   被否：`dsh-typert-protocol` 的 `TypertRemoteService` 是**继承**用的（`instanceof` 才致命），
   也必须与宿主同源；既然要升，就让整组一致，避免"半对齐"这种更难解释的状态。
3. **用 `workspace:*` / 指向 `D:\sudy\github\deepseek-harness` 的本地链接** —— 最强理由：永远跟着源码走，不会漂。
   被否：我们的 `node_modules` 是给**类型检查与单测**用的，指向源码树会让 `tsc` 读到工作区里未发布的改动；
   发版用的宿主是打包好的 app.asar，不是源码树。版本号对齐 + 定期核对才是稳的。

## Consequences

- `pnpm install` 从本地 store 直接解析到 rc.3（8.7 s，无网络请求），**lockfile 更新**一并提交。
- `tsc --noEmit` 0、`pnpm build` 通过、`pnpm test` **621 / 621**、flutter 1175 未受影响（App 不依赖这些包）。
- 真机侧的证据本来就成立：今天所有轮次（配对、`session.prompt`、`status` 帧、审批、用量）都跑在
  **rc.3 宿主**上；重启隔离实例后连接器照常加载（`[dsh-mobile] 管理面 RPC 已挂`、`8790` 在听）。
- **固定动作**（写进 `tools.md`）：每次 DSH 升级后先量宿主里的版本，再改 `connector/package.json`，
  跑 `tsc/build/test` 三件套；红了就**回退版本号**，不许为升版本改业务代码。
- 代价：以后再升级要重复这套（一条命令量版本 + 一次 install + 三件套），但那是几十分钟，不是几天。

## 代码入口回指

`connector/package.json`（peerDependencies / devDependencies）、`connector/pnpm-lock.yaml`。
量宿主版本的一行：

```powershell
$env:ELECTRON_RUN_AS_NODE='1'
& 'D:\soft\DeepSeek Harness\DeepSeek Harness.exe' -e "console.log(require('D:/soft/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/cordis/package.json').version)"
```
