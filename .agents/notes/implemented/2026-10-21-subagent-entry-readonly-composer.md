# Agent Note: 子智能体进入是“换主对话”，但一次性 / 未知模式必须只读

Status: implemented

## Problem

用户 2026-10-21 追问「这个子智能体进入你看 web 了没，他这个子智能体进入完全就又是一个
新的 web 对话页啥都有是吧？」。核 DSH 源码后确认：

- `openChild(address)` 调 `ctx.uiWorkspace.openSession(address)`
  （`ui-subagent/src/client/index.ts:61-63`），而 `openSession` 走
  `replaceMain(target, signal, 'reveal')`（`ui-workspace/src/client/navigation.ts:276-278,499-529`）
  —— **主对话区换成子会话**，不是右侧悬浮面板；聊天正文、头部、统计都还在。
- 但输入区不是无条件保留：`selectReadOnlySubagent`
  （`ui-subagent/src/client/index.ts:37-49`）在三种情况下接管 composer：
  `one-shot` / `unknown` / 父会话不可用且子会话已停。对应的
  `SubagentReadOnlyComposer`（`SubagentReadOnlyComposer.tsx:19-31`）只显示一句
  说明，不提供输入框。

手机端此前只做了第一半：`_openSubagentSession` 会 `openSession(child)` 并显示
面包屑，但 `DshComposer` 仍照常渲染、仍可发送。一次性的子会话收到 `session.prompt`
不会产生后续轮次，用户看到的是"发出去了但永远没反应"。

## Decision

**进入子会话仍是“换主对话页”；但 `one-shot` / `unknown` 的子会话把整条输入栏
换成只读说明，文案逐字照 DSH 的 zh 词典（`ui-subagent/src/client/locales.ts:55-60`）。**

- 模式从**父会话的 `subagentCatalog` 行**取（`{id, mode, ...}`），因为进入子会话后
  `subagentsOf(current)` 看到的是它自己的下级，不是它自己的 mode。
- `continuable` 保留正常输入栏，与 DSH 对 `selectReadOnlySubagent` 返回 `null`
  的分支一致。
- **`parentAvailable` 这一档不做假**：它不在 `session.list` 的字段里，连接器也没发；
  不猜"父会话离线"，只处理能确定的两档。
- 顺带修掉导航记忆的泄漏：进入子会话后再从抽屉打开别的会话，面包屑必须消失
  （`didUpdateWidget` 里比较 `currentSid` 与 `_subagentChildSid`）。

## Alternatives considered

1. **保持输入栏可发送，让电脑侧拒绝**
   - 最强的理由：手机不需要判断模式，连接器/宿主才是权威；少一个 UI 分支。
   - 为何被否：一次性子会话的 `session.prompt` 不是"被拒"，而是**落一条没有
     后续轮次的用户消息** —— 比报错更糟，用户会等一个永不到来的回复。
     Web 已经把这个判断放在 composer 层，照同一条。

2. **进入子会话时把整页换成"只读记录页"（隐藏统计 / 头部 / 工具栏）**
   - 最强的理由：一次性任务确实只是一个执行记录，少画控件更干净。
   - 为何被否：DSH 只替换 composer，正文、头部 lineage、统计都保留；用户要看的
     是完整执行记录。整页降级会丢掉"这是一个真实会话"的结构，也和 Web 不一致。

3. **把 `parentAvailable` 也补进连接器**
   - 最强的理由：这样能完整复刻 Web 的三档只读判据。
   - 为何被否：它是 client session 的快照字段（`session-controller/src/client/sessions/session.ts:75`），
     不在 `SessionSummary` 里；要补得先扩 `session.list` 契约与 Host 投影。
     当前没有真机证据表明这一档在手机上出现过，先不为此扩大方法面。

## Consequences

- 收益：一次性 / 未知模式不再出现"发出去没人接"的假动作；子智能体进入的页面
  结构与 Web 一致（同一个主对话页 + 面包屑）。
- 代价：`parentAvailable === false` 的 continuable 子会话仍显示可输入 —— 与 Web
  的第三档有差距，等 `session.list` 有该字段再补；这是一条**已知差异**，不是遗漏。
- 代价：只读说明占据原本输入栏的位置；键盘不会再弹，符合"不能发"的语义。
- 验证：`subagent_enter_test.dart` 两条（continuable 保留 composer / one-shot 换成
  说明），以及原有 `side_pane_test` 的 `onOpenSub` 与两步停。
