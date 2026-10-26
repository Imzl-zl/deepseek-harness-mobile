# 在新会话中分支（收口行的「分支」）

会话流里每一轮的收口行有「分支」：从这一轮的收口处 fork 出一个新会话并打开它。

## 1. 链路（与 Web 同一条）

| 环节 | 出处 |
|---|---|
| 触发 | 收口行（`turn/end` 那条，`app/lib/ui/chat_turns.dart` 的 `TurnProcessRow`） |
| 坐标 | 该条目的 `seq`（= `turn/end` 的序号）；桌面 `forkAt(turn.end.seq)`（`ui-chat/src/client/apply.ts:299-305`） |
| 协议 | `session.fork` `{sid, atSeq?}` → `{sid}`（契约 §5.7） |
| 宿主 | `SessionController.fork({sessionId, atSeq?})` → `{sessionId}`（`packages/api/session-controller/src/index.ts:432-443`、`types.ts:300-312`） |
| 标题后缀 | 连接器照 Web 客户端服务层：读源标题 → fork → `rename`（`client/sessions/service.ts:463-487`，宿主 fork 没有 `increaseTitle`） |
| 别名 | 子会话的 DSH id 过别名表，回 `sid`（与 `session.create` 同一条） |
| 列表 | 成功后手机重拉 `session.list`，子会话进抽屉 |

## 2. 标题后缀规则

逐字照 `increasedForkTitle`（`service.ts:132-148`）：尾部半角 `(N)` / 全角 `（N）` 各加一；
没有编号就加 ` (1)`。源标题取 `session.list` 行的 `projections.values.title`；
没有标题时取 cwd 目录名（与 Web 的 `displayTitleOf` 同一套，`service.ts:119-130`）。
**不用 DSH 会话 id 兜底**（Web 用）：id 不过线（契约 §5.1），拿它当标题会把宿主 id 显示出来。

## 3. 失败与重复点击

- `rename` 失败如实回错误（`internal` + 宿主原话）：fork 已经建了，桌面同样不回滚
  （`service.ts:484`）。手机上弹错误，源会话视图不变。
- **不带幂等键**：宿主 fork 没有键，桌面也是每点一次建一个。重复点击由界面兜 ——
  「分支中…」在途时按钮不再发请求。

## 4. 已知边界

- 子会话读完不会自动关闭源会话视图；用户自己回到源会话。
- 分支的标题后缀依赖源标题可读（`session.list` 行）；两个都取不到时**不改名**。
