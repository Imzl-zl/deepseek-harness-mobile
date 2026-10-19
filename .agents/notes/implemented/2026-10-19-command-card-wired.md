# Agent Note: 斜杠命令卡（command/run + command/done 从 OtherItem 接进对话流）

Status: implemented

## Problem

2026-10-19 摸到的"没有输出"之二：`command/run` / `command/done` 两个事件在
投影里**完全没有 case**，一路落到 `OtherItem`（只计数、不渲染）。

于是 `/goal`、`/compact`、`/permission` 这些在 DSH Web 上有
"命令名 + 结果文本"卡片的东西，在手机上**一条都没有**。而连接器的
`usage.summary` 用法说明、权限档切换（`permission.switch` 的写路径就是
`/permission <档位>` 斜杠命令，契约 §5.7）、上下文压缩，全都要经命令执行 ——
用户看不出"我点了权限切换，电脑上到底发生了什么"。

## 调查

### 1. 真实形状（从本会话自己的 goal 命令导出）

`~/.dsh/sessions/--D-sudy-myproject-dsh-mobile--/session-1f80f156-…/
session.v4.jsonl.zstd`：

```json
{"type":"command/run","seq":3,"data":{
   "commandId":"cmd-532bbefe-1","name":"goal",
   "args":" 首先我要睡觉了…","source":{"kind":"user"}}}
{"type":"command/done","seq":8,"data":{
   "commandId":"cmd-532bbefe-1","kind":"success",
   "text":"Goal created\nStatus: active\nObjective: …\nRounds: 0/256\n…"}}
```

关键三点：**`command/done` 不带 `name`**（只在 run 上）、**`kind` 是
`success`/`error`**、**`text` 是多段**。

### 2. 配对规则

DSH 自己的格式不变量（`session-format-v3-to-v4/README.md:244`）原话：
"Run ids are unique; completion has a prior run" —— 与 `tool/call` /
`tool/result` 同一形状。连接器的 `items.ts` 里也没有 command 分支
（`grep command` 零命中），所以这是**两侧都没接**，不是手机漏了。

## Decision

### 1. `core/items.dart` 加配对

`command/run` / `command/done` → `c:$commandId`，缺 `commandId` 时**抛错**
（不静默退化成 `<type>:<seq>`，同 `tool/call` 的纪律）。

### 2. `model/chat_item.dart` 加 `CommandItem`

`name` / `status` / `summary` / `detail`。**复用 `ToolCallStatus`**：
DSH 的 `stateOf`（`GenericCommandCard.tsx:12-15`）把 `outcome === null`
映成 running、`kind === 'error'` 映成 error、其余 ok —— 与工具三档逐字对应。

**不并入 `ToolCallItem`**：配对键不同（`commandId` vs `toolCallId`），
而 DSH 也是两套组件（`GenericCommandCard` 与 `ToolCard`）。合成一类会让
卡片措辞（"工具" vs "命令"）分叉。

### 3. 投影

- `command/run` → `running`，名字补前导斜杠（DSH 的 `name` 是用户敲的那串
  `goal`，而卡片标题要读起来就是"一条命令"），摘要是 `args`；
  无参数时说 `正在执行…`（DSH 的 `t('command.running')`）。
- `command/done` → 覆盖同一 itemId：名字从 run 继承（done 不带 name），
  状态按 `kind`，**摘要是 `text` 的第一行**（DSH 把整段 text 当 summary，
  而那是宽屏），明细是全文。复用既有的 `_firstLine(text, 120)`
  （工具摘要那一个截断上限，同一行文字同一尺度）。

### 4. `ui/chat_turns.dart` 加 `CommandCard`

照 `GenericCommandCard`：

| DSH | 这里 |
|---|---|
| `title = node.name ?? t('command.title')`（`:37`） | 命令名（等宽、roleTool 色） |
| `IconApiOutlineRegular`（`:9`） | `api` 图标（我们图标集里的名字） |
| `body = text.includes('\n') ? text : null`（`:40`） | **只有含换行才给展开** |

## Alternatives considered（否掉的）

- **合成 `ToolCallItem` 一类**：配对键不同、措辞要分叉，而 DSH 两套组件。否。
- **摘要放整段 `text`**（照 DSH 宽屏）：手机上摘要只能一行，整段会占满首屏。
  取第一行 + 展开看全文，信息不丢。
- **`took` 填耗时**：`command/run` / `command/done` 都没有耗时字段
  （只有 `time` 帧头时间戳，而那是事件时刻不是执行时长）。不编。

## Consequences

- 收益：`/goal` / `/compact` / `/permission` 这些命令在手机上有卡片了
  （命令名 + 结果摘要，多行结果展开看全文）。
- 代价：`ChatItem` 多一个子类型、`chat_turns.dart` 多一个卡片刻意与
  `ToolCard` 同形（这是**有意的重复** —— DSH 也是两个组件）。
- 测试：`app/test/command_item_test.dart` 9 项 —— 真事件投影（run/done/
  覆盖/名字继承/error 态/窗口外只剩 done）、itemId 配对与抛错、
  **真事件 → 投影 → 渲染三段贯通**（含"单行不给展开"那条 DSH 判据）。
- 全量门禁：`flutter test 769` / `analyze 0` / `format 0` /
  `boundary 281` / `icons 100` / `protocol 486+26+49`。

## 未验证的部分（说清楚）

**真机上没看到命令卡**：这台电脑（公司）的 DSH profile 里没有带
`command/*` 事件的会话（goal 会话在 CraftAgent 那台电脑上，搜索"goal"
只匹配到标题里没这个词的会话）。已用**真事件 + widget 测试**把
"投影 → 渲染"两段钉住，但**端到端的样子要用户在带命令的会话上看一次**。
