# Agent Note: 会话渲染补齐 DSH 有的四样（reasoning / 附件 / 工具明细 / 插话标），坏事件不再炸掉整批

Status: implemented

## Problem

真机反馈（2026-10-17）："会话的页面渲染，APP是完全没有渲染"。

逐条读 DSH 与真实会话日志（`~/.dsh/sessions/**/session.v4.jsonl.zstd` 按帧解压）
后，对话流的投影缺了四样，另有一个结构性故障模式：

1. **思考过程整块丢掉**：`assistant/message` 的 content 里
   `{type:'reasoning', text}` 与 `{type:'text', text}` 并存（真日志实测），
   而 `textOfContent` 不按 type 滤，reasoning 的 text 直接混进正文——
   Web 把它渲染成独立过程块。
2. **附件不可见**：用户消息 content 有 `{type:'image', attachment}` /
   `{type:'file'}` 块，手机上一声不响（用户以为附件丢了）。
3. **工具结果明细恒空**：`ToolCard` 支持展开（`.tool-body`），而投影从不填
   `detail`——"这个工具到底返回了什么"在手机上看不见。
4. **插话无标记**：轮次跑到一半从 next-step 插进去的用户消息与开轮输入
   长得一模一样。
5. **一条坏事件炸掉整批**：`itemIdOf` 对"已知类型缺身份字段"抛 `StateError`
   （契约 §5.2 的硬规则），而 `_onDelta` 在循环里直接调 `projectEvent`——
   一个坏事件让**整个 delta 的条目全部丢失**，症状正是"会话打开了但一条
   消息都不渲染"，且不报错（流监听里的未处理异步错误）。

## Decision

1. **逐条错误隔离**：每条事件单独 try，失败的记进 `_projectionFailures`
   （`AppModel.projectionFailureOf(sid)`），剩下的照常渲染；空态里说出
   "有事件没能渲染：<原因>"——少渲染的必须让人看见，否则会被当成"会话里
   就没有这些"。
2. **`textOfContent` 只取 `type == 'text'` 的块**；reasoning 另抽
   （`reasoningOf`），助手消息带 `reasoning` 字段，界面渲染成可折叠的
   "思考过程"块（默认收起——它经常比正文还长）。
3. **附件只计数**（`attachmentCount`，气泡下一行小字）：读附件要
   `session/attachment`，本期未接，但"带了 2 张图"这个事实必须说出来。
4. **工具结果进明细**（`toolOutputOf`，4000 字截断）+ `metadata.diffs`
   hunks 折成 +N/−M（DSH `diff-card-model.ts:29-41` 认的
   `{path, oldText, newText}` 三项；手机这一版不画 diff 正文）。
5. **插话判定逐字移植 DSH Web 的 `SteeringHistory`**
   （`ui-chat/src/client/model/steering-history.ts`）：从 next-step 被 claim
   掉的 id，随后作为 `user/message` 到达且 `source.kind === 'user'` → 插话。
   **不猜"running 期间的用户消息就是插话"**：排队发送的消息也是运行期间
   到达的，猜就会把排队消息标成插话。
6. **`_sameContent` 补新字段**：漏一个的症状是"结果到了但展开区是空的"
   （upsert 认为内容没变，于是不更新）。

## Alternatives considered（否掉的）

- **坏事件整批重试/重连**：重连治不了"这条事件就是缺 id"，且用户要为
  电脑侧的一条坏数据反复断线。
- **reasoning 混排在正文里**（现状的意外行为）：DSH 把它归入"过程"分组，
  混排让"哪句是答案"分不清。
- **附件渲染占位图**：没有字节（`session/attachment` 未接），画占位图
  等于摆一个点不开的东西；计数 + 明说"手机上不显示"更诚实。

## Consequences

- 收益：对话流第一次有思考过程、附件事实、工具明细、插话标记；
   单条坏数据不再让整个会话变白屏。
- 代价：`MessageItem`/`ToolCallItem` 各多三个字段；`projectEvent` 多一个
   `steering` 参数（跨事件状态由 AppModel 的 `_InboxTracker` 提供，
   投影层保持纯函数）；`_onDelta` 从"一把梭"变成逐条 try。
- `SessionStore._sameContent` 与 diffStat 比较是新增的绊线（防 upsert 静默）。
