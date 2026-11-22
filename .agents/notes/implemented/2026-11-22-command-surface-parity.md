# Agent Note: 命令面 = 宿主的命令表面（删掉白名单）

Status: implemented

## Problem

**现象**（2026-11-21 用户原话："桌面啥样就啥样啊？我们 APP 是干啥的，就是复刻桌面功能啊"）：
手机上打 `/` 只有 `/goal` 与 `/plan` 两条，而桌面 `/` 菜单里有 `/compact`、`/export`、
`/permission`、`/feedback` 与插件自带的命令，外加这一会话的技能目录。

**当时的实现**：连接器 `connector/src/handlers.ts` 有一份 `MOBILE_COMMANDS`
（`['goal','plan']`），既是 `command.execute` 的准入，也是 `repo.info.commands` 的名单。
它由三条判据支撑（结果全由 `{kind,text}` 承载 / 处理器自己是状态机 / 没有已存在的窄口），
判据本身没错，错的是**它的位置**：它把"这台电脑支持什么"从宿主手里抢到了连接器里，
于是手机与桌面的命令面**永远不一致**，而且每加一条命令都要在连接器里重新论证一遍。

## Decision

**命令面就是宿主的命令表面。**

1. 连接器删掉名单：`command.execute` 把任何以 `/名字` 开头的行**原样**交给宿主
   （名字的合法性由宿主的 `find(agent, name)` 判 —— 连接器再判一次就是第二份名单）。
2. `repo.info.commands` 报**宿主的整张命令表**：`CommandLineRunner.catalog()` 读
   `commands.list(agent)`（含 `description`，见 `interaction/commands/src/types.ts:56-66`），
   一条也不筛。手机 `/` 菜单因此是这张表的直接投影 —— **手机侧零名单**。
3. 命令表是 per-agent 的：`commands.list` 要一个活 agent，而 `repo.info` 是无会话的
   只读面，所以取**登记顺序里第一个活 agent** 的视图；一个活 agent 都没有时是空表。
   手机侧据此把 `repo.info` 的触发点补上 `openSession`（`app/lib/data/host_state.dart`）：
   刚连上时那一格可能是空的，开一次会话就补上。

**代价，写在明处**：

- **"跑成功但看不见"是可能的**：`/export` 的产物是电脑侧浏览器 ZIP、`/feedback` 的产物
  在会话之外。手机拿到的是 `{kind:'success', text}`，界面如实显示那句话，
  **不假装文件到了手机上**。产物面（手机端接收文件 / 查看反馈记录）是独立的一单。
- **崩溃窗口里的重发**只靠幂等表（`idempotency.ts`：同键合流 + 24 h 内命中缓存，
  落盘在 `dsh_mobile_core.json` 的 `dedupe`）。白名单里"处理器自己是状态机"那层保险
  对 `/compact` 这类**不存在**了 —— 与桌面 Web 客户端同一个暴露面（它也不去重），
  这是有意的对齐。
- 空表那一档需要一次 `openSession` 才能补上；连上就立刻打 `/` 时菜单可能是空的。

## Alternatives considered

1. **保留白名单，逐条加名字**（把 `/permission` 走窄口、`/compact` 定义好重发语义）
   - 最强理由：每条命令的呈现形态都能单独验证，风险最小。
   - 为何被否：那是"在连接器里维护一份与桌面不同的能力表"，而产品的定位是复刻桌面。
     每加一条都要重新论证三条判据，长期成本落在"每次 DSH 升级"上；而用户要的是
     "桌面有的都有"。
2. **菜单显示全量、但没形态的命令灰掉**（B 案）
   - 最强理由：用户一眼看到"桌面上有这些"。
   - 为何被否：灰掉的判据只能在连接器里（第二份名单的另一种写法），而且"点了没反应"
     与既有的"不画点不开的东西"冲突。要么能跑，要么不出现。
3. **手机端起一份名单**（Dart 常量）
   - 最强理由：一次往返都不省不了，但这些名字确实稳定。
   - 为何被否：那是第二份真值 —— 电脑上装个插件多一条命令，手机菜单里永远没有它。
4. **新开 `command.catalog({sid})` 方法**（让命令表跟着会话走）
   - 最强理由：per-agent 覆盖真的出现时，`repo.info` 的"第一个活 agent"就是错的。
   - 为何被否：今天没有 per-agent 覆盖（命令都注册在根 context）。真出现时再加，
     判据写在 `command-line.ts` 的 `catalog()` 注释里（那里已经写明届时该怎么改）。

## Consequences

**收益**

- 手机 `/` 菜单 == 宿主的命令表：电脑装插件 → 手机菜单立刻多一行，**手机零改动**。
- "哪些命令能在手机上跑"这个问题消失了 —— 它变成"宿主注册了什么"。
- 连接器少了一处政策（`MOBILE_COMMANDS` 与它的错误文案），少了一种"这条命令为什么不出现"
  的解释成本。

**代价**

- 与上面 Decision 里那三条一致（假成功风险、重发面、空表窗口）。
- `tests/support/fixture-handlers.ts` 的命令表桩从 `describe(names)` 改成 `catalog()`：
  金样里 `repo.info.commands` 的内容现在由**桩自己**决定，不再由白名单决定。

**判据**

- connector `tests/command-execute.test.ts`（12 条里改了 5 条）：注册过的命令一律原样
  交给宿主（含 `/compact`、`/export`、`/feedback`、`/permission`、`/select-model`）；
  连接器不替宿主判名字（`/no-such-command` 也转过去，宿主回 `matched:false`）；
  `catalog()` 从宿主读名字+说明、空说明不带该键、活 agent 缺失时回空表；
  `repo.info.commands` 一条也不筛。
- app：`repo.info` 触发点补 `openSession`；`file_open_test.dart` 的"能力位未知"一档
  改成让假电脑**拒掉** `repo.info`（`openSession` 现在会重读它）。
- 门禁：connector **885** 全绿（tsc / build / test）、app **1978** 全绿、
  `dart analyze --fatal-infos` 0、boundary / size / rpc-single-caller PASS。
- **未做**：真机复验（要重装包）；`/` 菜单的技能段 —— 桌面把 `skills.list({sessionId})`
  的目录拼进同一个菜单（`ui-skill/src/client/index.ts:171-184`，`trigger: '/'`,
  `order: 2`，子会话不出现），手机端**整块没接**，是下一单。

代码入口回指：`connector/src/handlers.ts` 的命令门注释、`connector/src/dsh/command-line.ts`
的 `catalog()`、`app/lib/data/host_state.dart` 的 `repoInfo` 那一格各有一行指向本篇。
