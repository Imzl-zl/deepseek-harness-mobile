# Agent Note: 排队条与插话/打断落地（`inbox` 投影 + `session.updateQueue` + `session.cancel`）

Status: implemented

## Problem

真机反馈（2026-10-17）："输入框中的模型，权限，消息排队，插队都没有对接吧"。

模型/权限两条的读写在 2026-10-15 已接（权限经 `permission.catalog` +
`/permission` 命令，模型经 `session/modelCatalog` + `session/select-model`），
真缺口是**排队与插话**：会话正在跑时发出去的消息排进下一个轮次，
手机上**看不见它排在哪、也没法撤**；运行中也没有"停止"。

DSH Web 的排队 dock（`ui-conversation/src/client/queue/QueueDock.tsx`）三个行内
按钮（编辑 / 删除 / 插话）走 `session/updateQueue`
（`@Remote('updateQueue')`，`session-controller/src/index.ts:462-465`），
主键在运行中且空草稿时是停止（`InputBar.tsx:323` 的 `primaryStops`）。

## Decision

1. **队列读 `inbox` 投影**（`{'next-turn': […], 'next-step': […]}`，
   随 `session.projections` 到手机，契约 §5.7 已把 `inbox` 列进核实过的键）。
   只列 `next-turn`（Web 同一条：插进当前轮次的已生效，不在队列里）。
   预览规则照 `QueueDock.tsx:20-27`（滤图片/文件块、块间空格、200 字封顶）。
2. **新方法 `session.updateQueue`**（连接器）：`{sid, itemId, action}`，
   action 是 DSH `QueueAction` 联合；**带幂等键**（用户指令，重发不该编辑两次）。
   错误码 `session/steer-unavailable` / `session/queue-item-not-found`
   两边错误码表**早就有了**（契约 §3.1）——这个面是契约预铺过的。
3. **新方法 `session.cancel`**（连接器，契约 §5.7 列了但一直没接）：
   `@Remote('cancel')`，语义"取消当前轮次但保留待处理收件箱"。**不带幂等键**。
4. **主键在运行中且空草稿时是停止**（照 Web `primaryStops`），
   停止键**不受"空草稿"门限**（`InputBar.tsx:325`：那会儿门是"有没有停止出口"）——
   第一版实现漏了这条，运行中正想停时那颗键永远灰的，被自己的测试抓到。
5. **插话门 = 会话在跑**（DSH 文案"仅运行中可插话发送"）；
   编辑只对**纯文本**项可点（DSH 的 `commands.ts:433-441` 同一条）。
6. **队列变化不推投影**：`agent/inbox/spliced` 事件触发重读投影
   （打开会话时用投影里的当前队列播种，恢复不漏）。

## Alternatives considered（否掉的）

- **新开一个 `session.queue` 查询方法**：队列是投影，再开一个查询方法等于把
  DSH 已有的投影面翻译一遍（"翻译层就是漂移层"，与 `session.projections`
  同一个理由）。
- **排队行内编辑器**（Web 的 `InlineEditor`）：触屏上没有可靠高度，换底部
  sheet，语义不变（保存发的还是 `{kind:'edit', content:[{type:'text',text}]}`）。
- **暂停/恢复整个队列**：DSH 没有这个原语，不自造。

## Consequences

- 收益：排队可见、可改、可撤、可插话；运行中可停止。方法面 29→30，
  **契约列了没实现的 5 个只剩 settings/credentials 四个**。
- 代价：连接器多两个 handler 与两个端口方法；测试替身全部要补
  `updateQueue`/`cancel`（`SessionsPort` 是宽接口）；app 多一个排队条
  （一个 StatefulWidget + 一个模型文件）。
- 契约 §5.7 表、`tools.md` 方法数、`memory.md` 的"x/29"三处计数同步改成 30。
