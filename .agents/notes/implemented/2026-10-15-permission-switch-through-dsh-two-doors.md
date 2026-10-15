# Agent Note: 权限切换照 DSH 的两扇门接，方法名按"看得见的动作"起

Status: implemented

## Problem

手机上"切权限档"这件事**看着接了其实没接**:输入栏那个 chip 背后是一个三档手抄枚举
（`app/lib/ui/dsh_composer.dart` 的 `AccessMode`），点完只改一个本地字段
（`chat_page.dart` 的 `_setAccessMode`）。用户切完看到图标变了，而电脑侧那个会话的
沙箱模式与审批策略**一点没变** —— 不崩、不报错，只是那句话是假的。

同时"有哪些档位可切"也没有第二份真值的余地：DSH 的预设表来自**部署配置**
（`packages/bundle/base/cordis.patch.yml:262-271` 配了 `read-only` / `workspace-write` /
`danger-full-access`）。手机手抄一份名单，电脑上加一个预设、改一个名字，手机上永远看不到。

## Decision

**两个方法，各对应 DSH 原生的一扇门，方法名按手机上看得见的动作起：**

| 方法 | DSH 依据 | 形状 |
|---|---|---|
| `permission.catalog` | `permissionPresets.catalog()`，`@Remote('catalog')`（`packages/interaction/permission-presets/src/index.ts:292`） | `PermissionCatalog = {options, defaultOptions, defaultPreset}`（`types.ts:26-33`），原样过线 |
| `permission.switch` | `/permission <档位>` 斜杠命令，注册在 `permission-presets/src/index.ts:255-276`，经 `commands.execute` 跑（`interaction/commands/src/index.ts:360`，方法体 `:361`） | 回 `{matched, execution?}`；`execution` 是 DSH 的 `{commandId, result}` 原样过线 |

**当前档位不开第三个读面**：它在 `permissions` 投影的 `{currentValue}`
（注册在 `permission-presets/src/index.ts:237-244`，wire view 在 `:243`），
随已有的 `session.projections` 到手机（`AppModel.permissionValue`）。
同一个状态只有一个来源 —— 再开一个读面就会有两份可能对不上的真值。

**写路径与 Web 逐字一致**：Web 侧 `live.command('/permission ' + preset)`
（`packages/client/ui-permission-presets/src/client/index.ts:126`）落到
`remote.commands.execute(sessionId, line, [])`
（`session-controller/src/client/sessions/session.ts:388`）。连接器做的是同一件事，
只把 `sessionId` 换成通道别名、再经 `agents.get()` 换成它要的 live root agent
（口径同 `dsh/questions.ts` 的 `agentOf`）。

准入门槛（可机械判定）：

1. **名单不许手抄**：`permission.catalog` 拿不到时界面说"拿不到目录"，
   不许回落到一个写死的三档列表。判据：`parsePermissionCatalog` 对
   `available != true` 与形状不对一律返回 `null`，而 UI 对 `null` 只给提示。
2. **三种"没切上"必须分开说**：电脑侧没有结论（`lastError`）/
   电脑上没有 `/permission` 命令（`matched: false`）/
   电脑侧回了 error（`result.kind === 'error'`，DSH 原文照显）。
   合成一句"切换失败"就等于把可修的变成不可修的。
3. **切完必须重读投影**：当前值只在打开会话时拉过一次，不重读就要等下次开会话才变
   （DSH 的投影变化走 `control` 流，本期没接）。
4. **命令注入这条边界要拦**：`preset` 是手机给的字符串，被拼进命令行。
   已核实 `parseCommand`（`interaction/commands/src/index.ts:125-132`）只把命令名之后
   的所有内容当 `rawInput`，所以换行**变不成第二条命令**；而 handler 自己
   `rawInput.trim()` 后与预设名精确比对（`:265-271`）。即便如此，`permission.switch`
   仍在 handler 侧拦掉空串与首尾空白（空串会让 DSH 回"当前预设是 X"，
   那是一次**假的切换成功**）。

## Alternatives considered

1. 放一个通用的 `command.execute`，手机想跑什么斜杠命令都行
   - 最强的理由：这才是"照形状透传"——DSH 有几十条斜杠命令（`/compact`、`/plan`、
     `/goal`、`/export`、各插件自带的），一个口全打开，将来每个面都不用再加方法。
     Web 侧本来就有这条路径（`ui-plan/src/client/index.ts:122`、
     `command-compact`、`command-goal`、`command-feedback` 都走它）。
   - 为何被否：契约 §5.7 的方法名是**封闭集**，每个方法对应手机上一个**人人看得见的动作**，
     而手机置灰按钮靠的就是 `repo.info` 报的那张表。一个通用命令面会让手机调到
     "移动端根本没有形态"的命令上 —— 它们的 `CommandResult` 只有 `{kind, text}`
     （`interaction/commands/src/types.ts:34-41`），副作用在电脑侧发生，
     手机上既呈现不了也撤不回来。本期只接"权限切换"这一个面，将来每个面各带自己的方法名
     （与 `session.select-model` 同一个命名口径：按动作起名，不按机制起名）。
2. 手机继续手抄三档，只把"当前值"接上投影
   - 最强的理由：改动最小，chip 能显示电脑侧真值，列表反正是这三档。
   - 为何被否：预设表是部署可配的，手抄名单就是第二份真值；而"切"这一半仍然是假的。
     只接读不接写，等于把"看着接了其实没接"留在原处。
3. 把预设的沙箱/审批捆也透传出来，让手机自己判断哪档危险
   - 最强的理由：手机上就能推"这一档会不会不再问我"，不用比对预设键。
   - 为何被否：`PresetOption` 只有 `{value, name, description?}`
     （`permission-presets/src/types.ts:13-20`）—— **捆不在目录里**，要拿它就得读
     `permissionPresets` 的私有面。而"哪档要过风险门"Web 已有明丈口径：
     `danger-full-access` 与 `auto` 两个常量
     （`ui-permission-presets/src/client/presentation.ts:4,7`），照抄即可。

## Consequences

- 收益：权限档从"改本地字段"变成"真的切电脑侧那个会话"；预设名单与当前值都来自电脑侧，
  手机不再维护第二份真值；三档手抄枚举（`AccessMode`）**已删**，
  `chat_page.dart` 的 `_accessMode` 本地状态**已删**。
- 代价：
  - 契约封闭集从 24 涨到 **26**（`permission.catalog` / `permission.switch`），
    三处计数（`tools.md`、契约 §5.7、`memory.md`）与两道门禁同步改过。
  - 权限面多依赖两个服务键（`permissionPresets` / `commands`）加已有的 `agents`，
    三者缺任何一个整块不挂（手机侧控件隐藏，与 DSH "键缺席即隐藏控件"同一条规则）。
  - **没有 live agent 的会话切不了**：`/permission` 要 `agent.session` 落生命周期事件。
    这时回 `internal`（不是 `session/not-found` —— 那个码的客户端动作是"从列表移除"，
    而这个会话是存在的）。表是封闭的，不为它加一个新码。
  - 风险门的判据是**预设键比对**而不是捆比对：部署若把 `read-only` 配成
    `approval: never`，手机上不会为它弹风险门。这是 Web 已有的口径，不是新引入的偏差。

代码回指：`connector/src/dsh/permissions.ts`（适配层）、
`connector/src/handlers.ts` 的 `permission.switch`（边界校验）、
`app/lib/model/permission.dart`（展示映射与解析）。
