# Agent Note: 渲染三处真缺陷按 DSH 源码修（工具名被结果覆盖 / 参数行是键名 / 系统消息内联 / hero 贴底）

Status: implemented

## Problem

真机反馈（2026-10-19，用户原话）：

> "首页显示在最下面你觉得合乎常理好看吗？然后就是会话渲染只有思考，工具调用，
> 没有输出，运行命令啥的"

逐条在真机上复现并定位（设备 `d61cf622`，装的是当日 00:15 构建的当前代码）：

1. **hero 贴在屏幕最底下**：截图里「探索未至之境」+ 两枚 chip 挤在输入框上方，
   上面一大片空白。代码里 `ConversationHero` 写的是
   `mainAxisAlignment: MainAxisAlignment.end`，注释自称"手机把这一叠放在弹性区的底部"。
2. **工具卡的名字被结果覆盖成"工具"**：`tool/result` 到达后卡片显示
   `工具 role, source, toolCallId, conten…`。真日志里结果消息**不带 `name`**
   （只有 `role` / `source` / `toolCallId` / `content` / `isError` / `id`），
   而投影从结果里读名字，读不到就退回 `'工具'`。
3. **工具参数行是 JSON 键名清单**：`tool/call` 的 data 是
   `{turn, step, callId, name, arguments}`，投影用 `summarize(data)` 摊平它 ——
   得到 `turn, step, callId, name, arguments`，而真正的参数在 `arguments`
   （一个 JSON 字符串）里。这一条**一直如此**，只是被第 2 条盖着没被发现。
4. **系统消息整篇内联**：`system/message` 在真日志里是**整份系统提示词**
   （上万字符），`developer/message` 是上下文注入。两者都被渲染成
   `SystemTurn(text)` 一条居中弱化小字，于是对话流开头横着一面巨墙。

另确认**不是缺陷**的一件事：`assistant/message` 的 content 里
`reasoning` / `text` / `tool-call` 三种块并存，且**可以一个 `text` 块都没有**
（纯工具回合）。那时"没有正文"是事实 —— 用户说的"没有输出"指的是上面 2/3/4
这三处把工具卡弄成了不可读的键名行、把系统提示词铺成巨墙，而不是正文投影丢了。

## Decision

判据全部取 DSH 源码（`D:\sudy\github\deepseek-harness`），四处各一处：

1. **hero 居中**（`packages/client/ui-conversation/src/client/skeleton/
   ConversationRoot.module.css:503-518`）：

   ```css
   /* Hero phase: the composer stack (hero chrome + workspace row + card) is
      flex-centered in the column; composer phase docks it at the bottom. */
   .composerHero { align-self: center; padding-bottom: 32px; }
   ```

   即 **hero 阶段居中（脚注让整叠略高于真中心），composer 阶段才贴底**。
   手机照抄：`MainAxisAlignment.center` + 底部 32。输入栏本身仍在屏幕最下方，
   不受影响。

2. **结果继承调用**（`packages/client/ui-chat/src/client/conversation-nodes/
   tool.ts:100-118` 的 `rootResult(match, previous)`）：
   `name: previous?.name ?? ''`、`args: previous?.args`、
   `call: {name, argsRaw}` —— **结果不重复携带名字与参数，从调用继承**。
   落地为 `projectEvent(previous:)`：同一个 itemId 上的前一个条目。
   `AppModel._onDelta` 按"本批优先、落表兜底"取它（`inBatch` 映射），
   因为 `store.upsertAll` 在整批之后才发生，而同一個 delta 里
   `tool/call` 与 `tool/result` 会先后到达。
   没有 previous（历史翻页只落到结果）时**不编名字**：`'工具'` + 空参数行，
   与 DSH 的 `call: previous == null ? null : …` 同形。

3. **参数行按 DSH 的 `deriveSummary` 推**（`packages/client/ui-tool/src/client/
   tool/models/tool-call-model.ts:227-241` + `TOOL_VARIANTS` `:45-72`）：
   解析 `arguments` JSON → 按变体取优先键（bash/pwsh 取 `description`→`command`；
   read 系取 `path`/`file_path`/`url`；search 系取 `query`/`pattern`/`url`；
   write/edit 取 `path`/`file_path`）→ 都没有就取参数里第一个非空字符串
   → 参数里一个字符串都没有才取原始首行。解析失败（流式中断）取原始首行，
   **不猜**。

4. **系统 / 上下文消息改成可折叠行**：DSH 对这两种事件各有一个带标题的节点
   （`register-node-renderers.ts:45,49` 的 `context` 与 `system-prompt`，
   标签文案 `locale.ts:116` 的「系统提示词」），默认折叠。
   手机与既有的「思考过程」**共用同一个折叠控件**（`_CollapsibleNote`）——
   两处结构逐字相同，各写一份必然漂。标签：`system/message` = 「系统提示词」，
   `developer/message` = `source.kind`（照 DSH `event-projection.ts:60-76`
   的 `contextProducer`，未知 kind 也照它说，不中文化）。

## Alternatives considered（否掉的）

- **在 `tool/result` 里找名字**：真实载荷没有这个字段（fixture 钉住了
  `containsKey('name') == false`），找了就是白找。
- **把参数行改成原始 JSON**：DSH 明确是"按变体取优先键"，原始 JSON 在
  390px 宽的一行里只会显示 `{"file_path":…` 然后截断。
- **系统消息整篇隐藏**：用户看不到"这条带了系统提示词"会以为会话缺东西；
  DSH 也是折叠而不是隐藏。
- **hero 保持贴底、只加一个"上滑查看更多"**：DSH 的 hero 阶段本来就是居中的，
  贴底是我们自己加的偏离，而它不是触屏必需（输入栏位置没变）。

## Consequences

- 收益：工具卡重新可读（名字 + 参数行）；系统提示词不再冲掉对话流；
  hero 回到 DSH 的居中形态。
- 代价：`projectEvent` 多一个 `previous` 参数（跨事件状态由调用方给，
  投影层保持纯函数）；`MessageItem` 多一个 `systemLabel` 字段
  （`SessionStore._sameContent` 已同步，漏字段的症状是"结果到了但展开区是空的"）；
  `SessionStore` 的 upsert 合并从"投影层自己读全部字段"变成"继承前一个条目"。
- 新增 `app/test/fixtures/real-session-events.json`：**真机落盘事件**
  （按帧解压 `session.v4.jsonl.zstd` 后导出，字段未改，仅两处长文本截断并标注）。
  它钉住的是"我们以为的形状与真形状不同"这一类缺陷 —— 手写形状的用例
  只会复述实现的假设。
- 测试：`real_event_projection_test.dart` 5 项（继承 / 无 previous 的兜底 /
  同批合并 / 三种块 / 图片计数）；hero 位置断言 1 项
  （**变异校验过**：改回 `end` 立刻红，fraction=0.73 > 0.6）。
  注意第一版位置断言量的是**容器** rect，`Column` 默认 `mainAxisSize.max`
  撑满弹性区，于是任何对齐下都一样 —— 空转。改成量标题子控件才钉住。
