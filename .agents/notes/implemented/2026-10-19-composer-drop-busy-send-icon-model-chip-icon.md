# Agent Note: 输入栏去掉「忙时发送」图标 + 模型 chip 改图标优先

Status: implemented

## Problem

真机反馈（2026-10-19，用户原话）：

> "首先输入框下的忙时发送行为没必要吧，设置中有，这个也不经常更换设置，占位置"
> "我们的输入款就设计不是和很好，模型占那么大"

两件事都在行控区那一行（`＋` / 模型 / 权限 / 忙时发送 / 发送）：

1. **「忙时发送」图标占着一颗 34px 恒宽位**，而它是**装完就不动的偏好**
   （排队 / 插话二选一），设置页「通用」里一直有同一选择
   （`settings_page.dart` 的发送模式行）。行控区五个位置放一个不常换的开关，
   还把权限图标往中间挤。
2. **模型 chip 光靠文字就吃掉左组一半宽度**：真机上的模型名是
   `step-5-preview · max` 这种 20+ 字符的 id（`_modelLabel` 取的是 model id，
   目录里有展示名才用展示名）。`max-width: 62%` 的上限只管"最宽多少"，
   不管"看起来有多宽" —— 于是左组只剩一小条给权限图标。

## Decision

1. **移除行控区的忙时发送图标**（`_IconChip(sendMode.icon)`）。当前模式
   **不丢**：发送键的 tooltip 在运行中且没草稿时是「停止」，有草稿时是
   「排队发送 / 插话发送」—— 用户仍然知道这句话会怎样。改模式的唯一入口
   收敛到设置页（那本来就是它在 DSH 里的位置）。
   **同时删掉 `_showSendModeSheet`**：它原来的调用点只有那颗图标，
   入口没了它就是死代码，而它与设置页那一行是**同一个选择的两个真值源**。
2. **模型 chip 改成「图标 + 名字」**（照 rikkahub 的
   `ModelSelectorButton(onlyIcon = true)`，
   `app/src/main/java/me/rerere/rikkahub/ui/components/ai/ChatInput.kt:309-313`）：
   图标 13px + 5px 间距 + 可压缩的模型名 + `· 推理等级` + chevron。
   名字被省略号截掉之后，"这是模型选择器"仍然认得出。
3. **图标取 `database`**：DSH Web 的模型触发器用的就是它
   （`ui-model-selection/src/client/ModelSelect.tsx:484` 的
   `IconDataOutlineRegular`，抽取进我们图标集时叫 `database`）。
   **不新造字形** —— `verify-icons.cjs` 只放行集合内的 100 个名字
   （2026-10-19 同一天踩过：写 `'model'` / `'file'` 两个集合里没有的名字，
   门禁当场红）。

## Alternatives considered（否掉的）

- **模型 chip 只留图标**（rikkahub 的 `onlyIcon` 字面执行）：手机上没有
  hover，纯图标钮要点开才知道当前是哪个模型；而"此刻用哪个模型"是
  **高频信息**（用户换模型比换权限档勤）。留名字、加图标是折中。
- **把忙时发送图标换成"运行时可改的入口"**：用户明说不经常换，
  而设置页已经有。留着就是占位置。
- **模型名缩短（截断成前 8 字符）**：那会让 `deepseek-v4.1-flash` 与
  `deepseek-v4.1-pro` 显示成同一个名字 —— 截断必须留给 `ellipsis`，
  不能预先截。

## Consequences

- 收益：行控区从 5 个位置回到 4 个，权限图标不再被挤；模型 chip 在长名字下
  仍然认得出是模型选择器。
- 代价：`DshComposer` 少一个 `onPickSendMode` 参数（`sendMode` 保留 ——
  tooltip 要用）；`ChatPageState` 少一个 `_showSendModeSheet`。
- **未做**：发送队列 dock（运行时发送要挂可编辑 / 发送 / 删除的队列）。
  那是独立一批，见 `memory.md` 的待办 1 —— 用户原话
  "运行时发送，它是会挂载输入款上面有个发送队列的可以编辑，发送，删除的"。
  我们有 `session.updateQueue` 与 `inbox` 投影（`queue_dock.dart` 已有雏形），
  缺的是"运行时自动挂载 + 与输入框的间距"。
