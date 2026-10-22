# Agent Note: 会话流轮组（阶段 1：整轮分组 + 可折叠过程）

Status: implemented

## Problem

用户 2026-10-22 当场指出：Web 与 App 的会话流**结构不同** ——
Web 一轮跑完是一条可展开的控制行（`已完成，用时 8s ⌃`），组内是过程；手机是**完全平铺**，
一轮 8 次工具就铺两屏。后果不是审美：① 没法"把这一轮收起来看下一轮"；
② 设置里「工作步骤展示」四档只能作用于单张工具卡；③ 收口行
（`第 4 轮 · 5 分 21 秒 · 2 条消息 · 1 次工具`）只是纯展示，DSH 那个位置是可点的开关。

方案与 DSH 侧调研见 `archived/2026-10-22-turn-groups-in-conversation-flow.md`
（阶段 2「语义过程组」按那份方案**暂不做**：390dp 上两层组头要两次点击才看到正文）。

## Decision

1. **轮号上移到 `ChatItem` 基类**（`int? turn`）。投影时由 `AppModel._onDelta` 算：
   事件自带 `data.turn` 就用它，否则用**最近一次 `turn/start`**（`_currentTurn`）。
   真机日志次序 `turn/start` → `step/start` → `user/message`（`session-4f50055e…`：
   93 → 95 → 96），所以用户那句话属于它前面那个 `turn/start`。
2. **分组纯函数** `app/lib/model/turn_groups.dart`：边界 = **条目自己的轮号变化**；
   开头没有轮号的条目落进"未归属组"，**永不折叠**（如实降级，不编轮号）。
3. **折叠只藏过程**（工具 / 命令 / 重试 / 压缩），保留用户消息、助手正文、收口行、
   审批与提问卡。依据 DSH 的 `processMember`（`ChatNodeSeat.tsx:78-83`）与
   "审批是等用户决策的东西，收起来等于找不到待办"。
4. **可折条件三条**：有轮号 + 有过程 + **已收口**（组里出现过过程摘要 / 异常结局行）。
   运行中的一轮不可折 —— DSH 的组头在 `turn.status !== 'closed'` 时整行不渲染
   （`TurnProcessNodeView.tsx:18`）。
5. **组头就是原来的收口行**：`TurnProcessRow` 加 `expanded` / `onToggle`，右侧一枚
   `chevronUp/Down`（DSH 是 `rotate(180deg)`），复制与用量 pill 留在原位。
6. **新增设置一行**「工作步骤收起时机」（`CollapseTiming`：`回答结束后` 默认 /
   `下次有新消息时`），落盘键 `collapse_timing`，存手机本地。
7. **空正文的助手消息不画**：`content: []` 的 `assistant/message`（工具那一步常见）
   原来会画出一行只有头像的空行 —— 折叠把工具卡收起来之后它格外显眼（真机踩到）。

## Alternatives considered

1. **只按 `turn/start` 记账条目切组**（原方案写的）
   - 最强理由：边界只在事件流里，语义最纯。
   - 为何被否：真机上恢复老会话时，窗口里未必带 `turn/start` ⇒ 整段历史都不可折，
     而"历史里每一轮也能收起"正是用户想要的。改成"条目自己的轮号"之后，
   `assistant/message` / `tool/call` 自带的 `data.turn` 就够用了。
2. **组头挪到轮次开头**（照 DSH 的 `processControl` = `turn.start.seq − 0.1`）
   - 最强理由：与 Web 完全一致，"折叠开关在它控制的内容上方"符合直觉。
   - 为何被否：我们这一行同时是 turn-tail（复制 + 用量），另开一行会有两条
     `第 N 轮`；而手机上内容都在上方，点末尾那行收起来更省手指。
     差异与代价写在 `docs/subsystems/turn-groups.md` §4。
3. **折叠时把用户消息也收起来**（"整轮一个组头"）
   - 最强理由：收起后一轮真的只占一行。
   - 为何被否：DSH 折叠的是过程节点，提示与最终回答是独立节点、始终可见；
     把"我问了什么"藏起来，用户在长会话里就失去定位。
4. **判"已收口"看组内最后一条是不是收口行**
   - 最强理由：一行代码。
   - 为何被否：`turn/end` 之后还会落几条没有轮号的记账事件（`request/*` 等），
     它们被并进这一组 ⇒ 已收口的一轮被判成"还在跑" ⇒ **真机上没有折叠箭头**。
     改成"组里出现过收口行"（这条是首轮真机验证当场修掉的）。

## Consequences

- 收益：一轮收成"提示 + 回答 + 一行组头"，点开才看过程；长会话里翻轮次快得多；
  「工作步骤收起时机」这一行终于有语义。
- 代价：
  - `ChatItem` 多一个字段、9 个子类的构造多一个 `super.turn`；`TurnProcessItem` /
    `TurnOutcomeItem` 的 `int turn` 变成可空（读的地方各加一次空判，`trajectory_page`
    的 join 跳过没有轮号的收口行）。
  - **展开 / 收起不改滚动位置**：`reverse: true` 的列表格数一变，用户点开的那一轮
    可能有一部分在屏幕外。要不要"保持被折叠块的相对位置"还没做；
  - 用户的手动展开/收起按 `(sid, turn)` 记住，**不落盘**（关 App 就回默认）；
  - 空洞期：历史窗口里没有轮号的条目（用户消息）自成一组、不折 —— 表现为开头或
    跨组的小段平铺，如实降级。
- 判据：
  - 纯函数 11 条（`app/test/turn_groups_test.dart`）：切分 / 重复 `turn/start` /
    历史窗口按轮号 / 可折三种 / 收藏范围 / 未归属不折 / 按轮分别判 / 收口行后还有
    记账事件仍算收口。**变异校验**：把 `applyTurnCollapse` 改成恒等（不藏任何条目），
    3 条红（2 纯函数 + 1 widget），恢复即绿。
  - 页面 3 条（`app/test/turn_group_collapse_test.dart`）：默认收起 → 点开 → 再收；
    空正文助手消息不留空行；`next-input` 档最新一轮默认展开、上一轮收起。
  - 真机（`d61cf622`，`adb install -r` 原地装）：`shots-2026-10-22/n1-collapsed-clean.png`
    （收起：提示 + 回答 + `第 5 轮 ⌄`，`run_code` 卡不见）与 `n2-expanded.png`
    （展开：`run_code` 卡回到提示与回答之间，箭头变 ⌃）；设置页
    `n3-settings-row.png`（「工作步骤收起时机 · 回答结束后」）。
  - 门禁：flutter **1097** / boundary **352**（97 个 Dart 文件）/ icons / tool-paths /
    analyze+format 全绿。
- 原型（`mock/proto`）**未同步**：那是交互基线，这一层结构还没有原型形态；
  按 `mock/proto/AGENTS.md` 的同一条，落地端领先时要在原型补齐同形行为才算收口 ——
  记为待办（与「子代理面板未跟上」同一类）。
