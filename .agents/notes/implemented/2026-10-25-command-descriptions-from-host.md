# Agent Note: 命令的说明从宿主的命令定义读，不在手机里抄一份

Status: implemented

## Problem

`repo.info.commands` 只报**名字数组**（`['goal','plan']`），于是 `/` 的候选行只有名字。
宿主的行有右侧说明，而且那说明来自**命令定义自己**：`commands.register({name, description})`
（`packages/interaction/commands/src/index.ts:79` 的 `CommandDefinition.description`），
经 `@Remote list(agent)` 的 `CommandDescriptor`（`types.ts:56-66`）发给界面。

手机要在那一列显示这句话，只有两条路：把「设置或查看长期任务目标」这类中文手抄进代码，
或者把宿主的定义读过来。前者是同一个事实两处表达 —— DSH 改词，我们永远看不到。

## Decision

`repo.info.commands` 的形状改成 `{name, description?}[]`：名字仍来自白名单
（`MOBILE_COMMANDS`，唯一一处真值），说明来自宿主 `commands.list(agent)` 的 `description`
（连接器 `dsh/command-line.ts` 的 `describe`，与 `execute` 同一段共用 `ctx.get('commands')`）。
读不到说明（一个活 agent 都没有）就**不带这个键**：手机那一列不画说明，不画一句编的。
手机侧两种形状都收（`model/command.dart` 的 `parseSlashCommands`）。

准入门槛（可机械判定）：

1. 线上那句说明**等于宿主注册表里的那一句**：连接器用例注入一句不可能被手抄到的字符串
   （`HOST-DECLARED-description-of-goal`），手抄实现必红；
2. 一个活 agent 都没有 ⇒ `describe` 回空表 ⇒ `repo.info.commands` 的每一项只有 `name`；
3. `command.execute` 没挂 ⇒ **整个 `commands` 键不出现**（与之前同一条判据）；
4. 手机：`{name, description}` 与 `['goal']` 两种形状都解出同样的名字，空说明视同没给。

## Alternatives considered

1. **把两条中文说明手抄进手机**（照 `ui-commands/src/client/locales.ts` 的
   `description.goal` = 「设置或查看长期任务目标」）
   - 最强的理由：手机上全是中文，这两句就是中文的权威文案；零新增耦合、零往返。
   - 为何被否：那是**客户端词典**的词，不是宿主的定义；抄进手机后 DSH 改词我们不知道，
     而且多出一份"哪条命令叫什么"的第二真值。手机也没有本地化层，抄了只是把一份英文的
     宿主数据和一份中文的手抄数据混在一起。
2. **新开一个按会话的方法 `command.list({sid})`**（照 Web 的
   `remote.commands.list(sessionId)`，`ui-commands/src/client/service.ts:108`）
   - 最强的理由：这是宿主真正的形状 —— 命令定义可以按 agent 作用域覆盖（`register` 走
     `ctx.effect` + `ScopedLayers`），只有 per-session 才能保证"看到的就是这个会话的"。
   - 为何被否：方法面是封闭集，加一个方法要让手机为一个**全局政策**（白名单）多一次按会话
     的拉取与缓存，而 `repo.info` 本来就在报同一份名单。取"第一个活 agent 的视图"在真实
     部署下等价（`/goal`、`/plan` 都注册在插件根 context 上）。**若哪天出现 per-agent 覆盖，
     这条就是该改的方向**，届时按 per-session 方法收口。
3. **不给说明**（`/` 的行只有名字）
   - 最强的理由：零成本、零新耦合，手机不需要知道宿主的定义长什么样。
   - 为何被否：用户点名了"命令的也是"，而宿主那一行本来就有说明列；数据只隔一次调用。

## Consequences

- 收益：说明跟着宿主走（改词不用改手机）；老连接器的 `string[]` 仍然能用；白名单仍只有一处。
- 代价：`repo.info` 的应答形状变了 —— 老手机（`whereType<String>()`）会把对象数组读成空表，
  于是不出 `/` 菜单（所以手机改成两种都收，新手机连老连接器则没有说明）；
  说明是**宿主定义里的英文原文**，手机不做本地化。
- 代价（真机证实，比当初写的更糟）：连接器 `describe()` 要一个**活 agent**
  （`connector/src/dsh/command-line.ts:189-203`），而手机只在**握手后那次**
  `refreshRepoInfo()` 取 `repo.info`（`app/lib/data/app_model.dart:2540`）—— 那一刻
  一条会话都还没打开 ⇒ 说明恒为空表。**本笔记原先写的"下一次 `session.list` 之后的
  `refreshRepoInfo` 就补上"不成立**：代码里没有那次刷新。

## 真机验证（2026-10-25）

仪器同 `2026-10-25-composer-panel-rows-drill-crumbs.md` 的同名一节。

- `/` 面板形状**对了**：section `指令`，`/goal` / `/plan` 两行、左对齐、无图标
  （宿主的命令图标表不在手机上，凭空配图标就是编数据 —— 与本篇的取舍一致）。
- **说明列在真机上一次都没出现过**，原因见上面最后一条"代价"：`repo.info` 在握手时取，
  那时没有活 agent；之后没有任何一处重取。宿主的 `description` 是**必填且非空**
  （`packages/interaction/commands/src/index.ts:183-188` 对空串直接抛），所以"宿主没给词"
  这个解释不成立 —— 是我们取数时机的问题。
- 这一条目前的状态：**两条单测都绿，生产路径恒空**。要收口得先定"什么时候重取"：
  候选是"第一次有会话订阅成功之后"或"打开会话时"，两者都要防抖（`repo.info` 是
  per-agent 全局面，不是 per-session）。未做。
