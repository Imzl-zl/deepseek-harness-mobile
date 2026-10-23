# Agent Note: 斜杠命令的执行面（`command.execute` + 白名单）

Status: implemented

## Problem

**现象**：手机上输入 `/goal 睡觉` 点发送，电脑侧不会建目标 —— 它是一条**普通消息**。
`app/lib/ui/chat_page.dart` 的 `_send()` 只有两条路：`session.prompt` 与 `subagent.prompt`。

**DSH 的执行面**（读源码，不是猜）：

- `commands.execute(agent, line, submittedAttachments, signal)`
  （`packages/interaction/commands/src/index.ts:360-366`，`@Remote` 在 `:360`）。
- 回 `CommandExecution | undefined`；`undefined` = 语法或名字没解析出来，且**不落日志**
  （`:367-370`；`command/run` 在 `:373-378` 才追加）。`CommandResult` 只有
  `{kind:'success', text?, sourceEventSeq?}` / `{kind:'error', text}`（`types.ts:34-41`）。
- 生命周期 `command/run` → `command/done` 靠 `commandId` 配对（`:373-388`），
  手机已经在渲染（`app/test/command_item_test.dart` 用真日志钉的）。
- `agent` 的线上键是 `agentId`，`signal` 不进 args（`tools.md` 的两条铁律）。

**Web 的输入流水线怎么判断"这是一条命令"**（本轮要回答的事实问题一）：

1. `packages/client/ui-conversation/src/client/input/machine.ts:144-149`：`draft.trim()` 后
   `startsWith('/')` ⇒ 进 `adjudicating`；否则直接 `default-sink`（普通消息）。
2. `packages/client/ui-commands/src/client/service.ts:319-366` 的 `matchEnter`：取第一个空白
   分隔的 token 去查**目录**；目录里没有这个名字 ⇒ 返回 `undefined`。
3. 同一个 `machine.ts:170-175` 的 `onAdjudicated`：`outcome === undefined` ⇒
   **回落 `default-sink`（当普通消息发出去）**；`'handled'` ⇒ 什么都不做。
4. 目录里有、但宿主 `execute` 回 `undefined`（目录漂移）⇒ `service.ts:425` 回一个**错误**
   结果（"unknown or malformed command"），**不回落**，草稿留在输入框。

所以 Web 的答案分成两件事：**不认识的斜杠行退成普通消息**，**宿主没接住则报错**。
分得开是因为 Web 有目录；手机没有。

**契约 §5.7 的反对意见**（`docs/subsystems/remote-channel.md` 的 `permission.switch` 行末）：
方法名是封闭集、每个方法对应手机上看得见的动作；通用命令面会让手机调到移动端没有形态的命令
（`/compact`、`/export`、插件自带的），而 `CommandResult` 只有 `{kind,text}` ——
副作用发生了，手机上既呈现不了也撤不回来。

## Decision

**加一个方法 `command.execute`：参数 `{sid, line}`，回 `{matched, execution?}`；
命令名白名单在连接器（`connector/src/handlers.ts` 的 `MOBILE_COMMANDS`），本期只放 `/goal` 与 `/plan`。**

不推翻 §5.7 的反对意见，而是把它做成**可机械判定的准入门槛**（三条都要成立）：

1. **结果全部由 `{kind,text}` 承载，且不产生会话之外的新产物** —— 手机拿不到的东西
   （ZIP 下载、反馈记录）发生了也呈现不了。
2. **效果是会话级状态，且处理器自己是状态机**：非法转移被拒、重复执行落到同一终态。
3. **没有已存在的窄口。**

逐条落：

- `/goal`（`packages/goal/command-goal/src/index.ts:191-197`）：目标在会话里、模型下一轮读到；
  `create` 在已有目标时被拒（`:143-149`），`clear` 重复是 no-op（`:171-174`）。
- `/plan`（`packages/plan/plan-mode/src/index.ts:230-274`）：`set` 回
  `committed / queued / cancelled / noop`。
- `/compact`：**没有反向命令**，且一次调用就是一次模型总结
  （`packages/compaction/command-compact/src/index.ts:67`）—— 第 2 条不成立。
- `/export`：产物是浏览器下载（`packages/session-query/session-log-export/src/index.ts:79-86`）；
  `/feedback`：产物是会话之外的反馈记录（`packages/feedback/command-feedback/src/index.ts:73-83`）
  —— 第 1 条不成立。
- `/permission`：第 3 条不成立 —— `permission.switch` 就是它的窄口，同一个状态不开第二条路。

**第 2 条同时是幂等的答案**（本轮要回答的事实问题三）。键是 `requestId`
（`IDEMPOTENT_METHODS`），它只覆盖"同键合流 + 24 h 内命中缓存"；**崩溃窗口里的重发**
（`connector/src/idempotency.ts` 文件头第二节）对命令**不是免费的** —— DSH 不按 `rpcId`
给命令去重（`execute` 每次都铸新的 `commandId`）。之所以安全，是因为白名单里的处理器
自己是状态机：第二次 `/goal …` 落到"已有一个目标"的拒绝上，`/plan` 重复落到 `noop`。
**白名单的第 2 条判据与"崩溃窗口可重发"是同一个事实** —— 所以它们只能一起变。

**手机侧**（事实问题二的落点）：**一处分流** `sendRouteOf`（`app/lib/model/command.dart`）——
命令 → `command.execute`、普通文本 → `session.prompt`、**子会话恒 `subagent.prompt`**
（子会话没有命令面：`commands.execute` 要一个活的 root agent，而子会话唯一的写入口是
`subagents.prompt`）。`matched:false` 按 Web 第 3 步退成普通消息并说一句；异常 / 形状认不出
如实报且文本留在输入框；只有 `matched:true` 才清空输入框（结果在命令卡上）。

**为什么 `matched:false` 是回落而不是报错**：手机没有目录，"电脑不认识"是它唯一能拿到的
"这不是命令"的信号，而 Web 在同一个信号上的动作就是回落。**白名单拒绝不能回 `matched:false`**
—— 那会让 `/compact` 悄悄变成一条消息，正是本轮要消灭的形状；它回 `connector/unsupported`
（客户端动作 `disable`）加一句带名单的人话，手机原文显示。

**实现上的收窄**：两扇门（`permission.switch` / `command.execute`）落到**同一段**
`connector/src/dsh/command-line.ts`（别名 → 活 agent、60 s 超时、`undefined` 的语义）；
白名单只在 `handlers.ts`（方法面的政策）；手机侧不抄名单。

## Alternatives considered

1. **不加方法，让 `/goal` 继续走 `session.prompt`**（现状）
   - 最强理由：零新方法面、零新代码，手机与电脑永远"一致"。
   - 为何被否：它把一条**有副作用的人类指令**降级成一段给模型的文本 —— 目标不会建、
     命令卡不出现，而用户看不出区别。这正是本轮要修的 bug。
2. **推翻 §5.7，开一个无白名单的通用命令面**（与 Web 完全一致）
   - 最强理由：§0 的不变量是"Web 调哪个，手机就调哪个"，而 Web 的命令面**不设白名单**：
     任何注册过的命令都能跑，功能最完整、也没有第二份名单。
   - 为何被否：§5.7 的反对意见说的不是"命令危险"，而是"**手机上呈现不了**"。
     `/export` 的成功是浏览器下载一个 ZIP，手机只拿到
     `{kind:'success', text:'Session log download requested.'}` —— 用户会以为日志导出到手机上了；
     `/feedback` 同理（记录在会话之外）。要么在手机上补出这些形态，要么承认它们没有形态。
     本期补不出，所以白名单。
3. **白名单放在手机侧**（Dart 常量）
   - 最强理由：手机自己知道哪些能发，连一次拒绝往返都省了。
   - 为何被否：那是第二份名单。"这台电脑注册了哪些命令"只有电脑侧知道（部署与插件都会变），
     手机上的常量迟早变成谎言。
4. **白名单放手机侧 + 连接器发布名单**（`repo.info.commands`）
   - 最强理由：只有一处真值，手机还能据此画 `/` 菜单。
   - 为何被否：本期没有命令菜单这个面。为它先加一个 `repo.info` 字段，等于给一个还不存在的
     UI 造接口；真要做菜单时再加，届时名单仍然是 `MOBILE_COMMANDS` 这一处。
5. **`matched:false` 当失败报错**（不回落成消息）
   - 最强理由：`/goal` 变成消息正是 bug，报错至少不会"静默"。
   - 为何被否：它会让 `/etc/passwd 是啥` 这种**正常提问**发不出去，而 Web 上它是消息。
     "回落 + 一句提示"两者都保住了。
6. **白名单拒绝也回 `matched:false`**
   - 最强理由：形状最少，手机一个分支搞定。
   - 为何被否：手机在 `matched:false` 上的动作是"当普通消息发出去"，于是 `/compact` 会悄悄
     变成一条消息 —— 用户以为压缩了，其实只是说了一句话。这是本轮明确要消灭的形状。

## Consequences

**收益**

- `/goal …` 在手机上真的建目标；结果落在命令卡上（`command/run` + `command/done`，渲染没动）。
- 命令的执行语义只有一处（`dsh/command-line.ts`）：`permission.switch` 与 `command.execute`
  的"没有活动 agent / 超时 / `undefined`"三条逐字相同。
- 白名单的准入判据可机械判定，且第 2 条同时是崩溃窗口可重发的依据 —— 两条规则不会各说各话。
- 应答解析只有一处（`parseCommandOutcome`），`permission.switch` 跟着换掉，不再有两份解析。

**代价**

- 手机上**只有两条命令**能跑；`/compact`、`/export`、`/feedback` 与插件自带的命令都会被拒
  （带一句人话）。要加一个名字，得先满足那三条判据。
- **旧连接器 + 新手机**：`command.execute` 不存在 ⇒ 任何以 `/` 开头的行都会报
  "命令没有执行：未知方法"（此前它会当消息发出去）。这是一次可见的兼容断裂；
  连接器与手机同批发布时不可见。
- 子会话里的 `/…` 仍是普通消息（子会话没有命令面）—— 与"子会话只有 `subagent.prompt`
  一个写入口"同一条边界。
- 命令不携带附件：输入框里有图片时命令会被拒（明说，不悄悄丢图）。"上传文件"仍是独立的开工单。
- 崩溃窗口里重发一条命令可能落两张卡（第二次通常是拒绝），状态不会坏；
  `idempotency.ts` 的"重复执行为什么安全"那张表多一行**依赖"处理器是状态机"**的条目。
- 门禁：connector **587 → 599**、flutter **1127 → 1137**、boundary **357 → 360**；
  **0 个真机回合**。

**判据**

- `connector/tests/command-execute.test.ts` 12 条：方法名与幂等键、命令名语法与 DSH 逐字一致、
  请求形状（agent 由 sid 解析 / 附件 `[]` / 带 signal）、`undefined → matched:false`、
  `{kind:'error'}` 原样过线、白名单放行与拒绝（拒绝时**不去问 DSH**）、非命令形状交给宿主、
  坏参数 `bad-frame`、未知 sid `session/not-found`、没有活动 agent `internal`、
  能力位缺席不挂方法。
- `app/test/command_send_test.dart` 10 条：分流（命令 / 普通 / 子会话）、
  `executeCommand` 的参数与幂等键、`matched:false` 不写 `lastError`、失败留声、
  形状认不出留声、四个聊天页接线用例（命令 / 普通 / 回落 / 失败留文本）。
- 变异校验（都做过）：
  1. 把 `_send` 的分流固定成 `SendRoute.prompt` ⇒ **恰好 3 条红**（三个命令接线用例），
     其余 7 条绿；
  2. 关掉白名单那个 `if` ⇒ **恰好 1 条红**；
  3. 把 `undefined` 也当 `matched:true` ⇒ **恰好 2 条红**（执行面那条 + `permission.switch`
     的同一条 —— 共用一段的旁证）。

代码入口回指：`connector/src/dsh/command-line.ts` 与 `connector/src/handlers.ts` 的
`MOBILE_COMMANDS`、`app/lib/model/command.dart` 的文件头各有一行指向本篇。
