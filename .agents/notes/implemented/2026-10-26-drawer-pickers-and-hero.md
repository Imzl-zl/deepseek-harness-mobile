# Agent Note: 抽屉菜单层级、模型/推理面板去噪、首页不显示分段

Status: implemented

## Problem

用户在真机上连提四条（原话）：

1. 「左侧抽屉的工作区列表和会话列表，你觉得你设计的好吧？按照菜单的分级，工作区属于一级菜单，
   你看你搞的大小还是浅色，一眼看过去看不出来，谁家一级菜单这样？会话列表你可以缩进一下」
2. 「模型选择……APP 下面还有一堆废话……你就显示渠道和模型不就行了」
3. 「思考选择你也看看，我昨天点好像没反应」
4. 「会话首页，之前都说了没有会话不用显示上面的对话轨迹是吧？我感觉好像首页的时候还会显示」

## Decision

1. **层级**：工作区组头 = 13px / w700 / `labelPrimary`（当前所在组仍用强调色），文件夹图标 15；
   会话行整体缩进 14px（`CollapsibleGroup.indent`）。层级靠"缩进 + 字重 + 颜色"三样，
   不再只靠 11px 浅色。
2. **模型面板**：分组头＝渠道（`group.name`），行＝模型名（`entry.displayName`），
   **不显示** `description`、也不显示"N 档推理等级"。推理等级面板同理只留档位名 +
   「提供商默认」标记。
3. **思考选择**：根因是 `ChatPage` 从来没把 `onPickReasoning` 传给 `DshComposer`
   （chip 的 `onPressed` 为 `null`）。现在接到 `_showReasoningSheet`：按**当前模型**从目录取
   `reasoning`，复用模型面板的第二级（`_showEffortSheet`）；取不到时如实 toast 一句。
4. **首页**：`blank` 会话（hero 屏）不再画「对话 / 轨迹」分段，正文强制走对话页。

## Alternatives considered

1. **工作区组头加背景色块来强调层级**
   - 最强的理由：块状比字重更"一眼看出"。
   - 被否：抽屉里已经有一层"我的电脑"卡片，再叠色块会把列表压成洋葱；
     字重 + 颜色 + 缩进在 DSH 的侧栏里本来就是这个表达（`Rows.tsx:259-263`）。
2. **模型面板保留"说明文字"作为信息**
   - 最强的理由：宿主的 `description` 是给用户看的。
   - 被否：用户明确说"一堆废话"；渠道由分组头表达，档数点进去就看见，
     说明文字在手机上只挤占行高。
3. **把无档位模型的点击也当作"切模型"**
   - 最强的理由：少一个分支。
   - 被否：`_pickModel` 已经这么做了（无 `reasoning` 时直接切）；
     真正缺的是**chip 到面板的接线**，不是这条分支。

## Consequences

- 收益：抽屉层级一眼可辨；两枚面板只剩"渠道 / 模型 / 档位"。
- 收益：「思考」chip 不再是一个点了没反应的按钮（真机确认的 bug）。
- 收益：首页只剩 hero，不再有"点了没内容的轨迹 tab"。
- 代价：模型面板丢掉说明文字后，模型差异只能靠名字判断（手机上没有 hover 可看详情）。
- 代价：`CollapsibleGroup.indent` 对所有使用方生效（抽屉与内联列表都是二级缩进，
  这对"工作区 → 会话"的层级是正确的）。

## 代码入口回指

- `app/lib/ui/collapsible_group.dart`（组头字号/字重/颜色 + `indent`）
- `app/lib/ui/chat_page.dart`（`_showModelSheet` / `_showReasoningSheet` / `_showEffortSheet`、
  `onPickReasoning` 接线、blank 不显示分段）
- `app/test/composer_pickers_test.dart`（四条规则各一条用例）
