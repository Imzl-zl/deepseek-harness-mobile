# Agent Note: 流式条目与持久条目同形（思考不再冒充正文）

Status: implemented

## Problem

真机症状：生成过程中满屏是**模型的思考**，而且找不到可点的「思考过程」折叠行；
落定之后那一段又变回折叠行。同一个内容在"生成中"和"生成完"是两种形态。

根因在累加器：它只读 `chunk['text']`，**不看 `chunk['type']`**
（`app/lib/core/sync_client_impl.dart` 的旧 `LiveAccumulator`）。而宿主同一路
assistant 流里两类增量都在（`packages/llm/llm/src/assistant-stream.ts:57-70`）：

```text
{type:'text-delta', index, text}
{type:'reasoning-delta', index, text}
{type:'tool-call-delta', index, id, name, argumentsDelta}
{type:'block-start'|'block-end'|'usage'|'finish', …}
```

于是思考被当正文累加、按 Markdown 全展开渲染；持久 `assistant/message` 到达后，
投影层才按块种类把它拆回 `reasoning` 与 `text`（`data/projection.dart` 的
`reasoningOf` / `textOfContent`）。

次生后果是性能：流式尾条目每收一批就整段重排一次，而被重排的文本里多了一份
通常比答案更长的思考。

单测没抓到它，因为用例喂的形状是假的 —— `test/sync_client_test.dart` 造的是
`chunk: {'text': text}`，从来没有 `type`（`memory.md` 教训 8 的同一类）。

## Decision

三条，都在"形状"这一层：

1. **累加器按块种类分流**：`core/live_message.dart` 的 `LiveMessageAssembler`
   产出 `LiveMessage {reasoning, text}` —— 与持久那一侧折出来的两段**同形**。
   `SessionDelta.liveText: String?` 换成 `liveMessage: LiveMessage?`；
   `AppModel.liveTail` 的类型跟着换。
2. **一条通知带两段**：`ValueListenable<LiveMessage?>`。分成两条订阅会让尾条目
   一帧重建两次，还可能画出一帧"只有正文、没有思考"的中间态。
3. **尾条目与持久条目并排**：`_LiveTurn` 从 `chat_page.dart` 搬到
   `chat_turns.dart` 改名 `LiveAssistantTurn`，紧挨 `AssistantTurn`；思考走同一个
   `ReasoningRow`，流式时 `running: true`（标题扫光 + 摘要取"最后完成段落首行"，
   照 `ReasoningRow.tsx:64`）。正文 `selectable: false`。

流式正文不给选择器：`selectable` 每帧要重挂一遍选择注册，而流式文本每 50 ms
变一次。同一段 4 KB 中文+列表+行内代码，在 flutter_test 的 debug 绑定下量到：

| 路径 | 单帧 |
|---|---|
| `MarkdownBody(selectable: true)` | 303 ms |
| `MarkdownBody(selectable: false)` | 33 ms |
| 纯 `SelectableText` | 13 ms |

绝对值是 debug JIT，不能当 release 预算；比例（选择器 9 倍）与形状是稳的。
生成中本来也没人会划选，落定条目照常可选。

## Alternatives considered

1. **在 UI 层按文本猜"哪一段是思考"**
   - 为何被否：猜不出（思考与正文都是自由文本），而且猜错会把正文切开；
     真值在 `chunk.type` 里，不读它就是放弃现成的判据。
2. **拆成两条订阅（`liveText` + `liveReasoning`）**
   - 为何被否：一帧两建；两段不同步时还会画出中间态（思考在、正文还没到）。
3. **只过滤掉 `reasoning-delta`，不显示思考**
   - 为何被否：生成中思考就彻底不可见 —— 桌面是"折叠行 + 摘要在走"，不是隐藏；
     而推理模型的长思考正是"它现在在干什么"的唯一线索。
4. **在 connector 侧过滤**
   - 为何被否：通道层只转发宿主帧（`connector/src/session-subscriptions.ts` 原样
     转发 `chunk`），内容语义属于客户端投影；而且 `live` 与 `job` 的分流判据也在
     那一层，不在那里做第二套解释。

## Consequences

- 两段成为流式内容的**唯一形状**；块的先后顺序不保留 —— 与持久那一侧一致
  （两个折串函数都是"同类块拼接"），所以落定那一帧不会换构造。
- 生成中正文不可划选；落定后照常（`DshMarkdown.selectable` 的默认仍是 `true`）。
- `LiveMessage` 实现 `==`，相同内容不触发通知（一批里两次赋值只重建一次）。
- 用例改成线上形状，并加了一条"思考一个字都不许进正文"的回归
  （`test/sync_client_test.dart`），以及流式思考行的渲染用例
  （`test/live_reasoning_test.dart`）。
- 未做（同一条链路上的下一批）：流式**块级冻结**（DSH
  `ui-primitives/src/markdown/incremental.ts` 的 `UNSTABLE_TAIL_BLOCKS = 2`）与
  阅读位置补偿（倒序列表最新端增长会把阅读内容顶走，已量到 100 px 的位移）。
