# Agent Note: a11y 第四批 —— 文件面板、会话流可折行、用量与端点行

Status: implemented

## Problem

`implemented/2026-11-12-a11y-sheet-and-trajectory.md` 定下的推进方式是"按屏补 + 每屏一条
`isSemantics(...)` 用例"。`node .agents/tools/count-a11y-candidates.mjs` 报 **57 处**候选，
但**那是上界不是清单**：脚本从 `InkWell(` 往上找 5 行，`Tooltip` 在上面也算命中，
上一轮实测假阳性约 1/3。这一批按"每天点得多"挑了四屏，逐处读过"这一下点了会发生什么"：

| 位置 | 候选 | 逐处读的结论 |
|---|---|---|
| `ui/files_pane.dart` 两段清单 | 2 | 上一批从 `chat_page.dart` 搬出来的（只搬不改行为），于是 a11y 没跟上：改动清单行点开 diff / 文件，差异行点一下**复制路径** —— 两个都是真动作 |
| `ui/chat_turns.dart` | 7 | 6 处是真动作（工具卡 / 重试 / 压缩 / 轮组头 / 操作胶囊 / 折叠行）；`TakeoverHint` 是**假阳性** —— 唯一调用点（`chat_page.dart:4027`）不传 `onTap`，本来就是纯展示 |
| `ui/settings_page.dart` 行内 | 2 | 端点行点一下 = **设为首选**（选择类行，`isFirst` 就是它的勾选态）；「已删除 N 条端点」点一下开恢复清单 |
| `ui/usage_page.dart` | 3 | 热力图一格（选中当天并改上方读数）、范围胶囊（切窗口要重拉）、项目头（收起 / 展开） |

顺带读到一处**真的假入口**：`_RangeChip` 的 `onTap` 恒非空
（`() => onSelectWindow?.call(...)`），所以页面没接 `onSelectWindow` 时三枚胶囊
有按钮角色、有水波、点了什么都不发生。

## Decision

1. **六处会话流行**：`Semantics(button: <这一行此刻有没有去处>)` 包住原 `InkWell`，
   条件由各自的数据决定 —— `hasDetail` / `expandable` / `hasSummary` /
   `widget.onToggle != null` / `expandable`。`_Pill` 恒有去处，直接 `button: true`。
2. **两段文件清单**：同上一条，`button: true`（两行都有真实后果）。
   差异行**不加 hint**：它有可见路径，按钮角色 + 文字已经说清"点它做什么"的一半；
   另一半（复制）由 toast 兑现，本仓没有在语义层再编一句话的先例。
3. **端点行**：`Semantics(button: true, selected: isFirst)`。`isFirst` 而不是 `isActive` ——
   点这一行改的是**队列顺序**（首选），不是"立即连"；「当前连接」是另一件事实，已经在行里
   有文字（`_statusOf` 四档）。同一个事实只有一套说法。
4. **热力图一格**：`Semantics(button: true, selected: selected, label: <哪天 · 几轮 · 多少 tok>)`
   + `GestureDetector(excludeFromSemantics: true)`。**这一格没有文字**（信息全在颜色深浅里），
   不给 label 就是一个无名按钮，所以新增 `label` 参数，取值来自 `_dayLabelOf` ——
   与上方读数行**同一个函数**（两处各写一遍必然漂成"图上一套、读数另一套"）。
   手势不再自己造节点，动作挂在 `Semantics` 上：同 `trajectory_timeline.dart` 的取舍。
5. **范围胶囊**：`button: onTap != null, selected: selected`，并把 `onTap` 改成可空
   （`_ActivityCard` 传 `onSelectWindow == null ? null : …`）—— 顺手把那处死按钮关掉。
6. 两处**不改**：
   - `TakeoverHint`（`chat_turns.dart:1561` 的候选）：`onTap` 为 `null`，`InkWell`
     只留下"No tap"的空实现，不报角色也不接水波 —— 已经是对的，脚本命中的是它的**上方 5 行**
     里那段 `Material`。
   - `_RangeChip` 的候选行同理（`Semantics` 在 `Material` 外层，脚本只看 5 行）。

## 准入判据

| 用例 | 钉什么 |
|---|---|
| `app/test/files_pane_semantics_test.dart` 第 1 条 | 改动清单行：按钮 + 动作；路径与 `+9` **仍读得到**；语义动作 ⇒ `file.diff{seq:6,index:0}` |
| 同文件第 2 条 | 差异行：按钮 + 路径；语义动作 ⇒ `Clipboard.setData` 收到**这一行**的路径 |
| `app/test/chat_turns_semantics_test.dart` 第 1 条 | 工具卡：有详情 ⇒ 按钮且点开正文（`总用量 12` 出现）；没详情 ⇒ **不是**按钮 |
| 同文件第 2 条 | 重试行：可展开 ⇒ 按钮；原因 / 延迟 / 错误码都空 ⇒ 不是按钮 |
| 同文件第 3 条 | 压缩行：有摘要 ⇒ 按钮；没摘要 ⇒ 不是按钮 |
| 同文件第 4 条 | 轮组头：`onToggle != null` ⇒ 按钮；为 `null` ⇒ 不是按钮 |
| 同文件第 5 条 | 操作胶囊「复制」是按钮（名字来自可见文字） |
| 同文件第 6 条 | 命令卡折叠行：多行 ⇒ 按钮；单行 ⇒ 不是按钮（DSH `text.includes('\n')` 同一条） |
| `app/test/settings_page_test.dart` 新增 2 条 | 端点行：首选那条 `isButton + isSelected`、另一条只有 `isButton`；「已删除」行是按钮且语义动作真开了 sheet |
| `app/test/usage_page_test.dart` 新增 3 条 | 热力图一格：有名字（`3 轮` / `8.4K tok`）、是按钮、点完 `isSelected`；范围胶囊：角色 + 选中态，没有回调时**不报按钮**；项目头是按钮且语义动作真收起了会话 |

**每一处都同时钉"有去处"与"没去处"两面** —— 只钉前者的话，把 `button: true` 写死也不会红。

变异校验（每条都先 `grep` 确认变异落地）：

| 变异 | 结果 |
|---|---|
| `files_pane.dart` 两处删掉 `button: true` | 恰好 2 条红（`Expected: has semantics … isButton`） |
| `chat_turns.dart` 六处 `button:` 全写成 `true`（写死） | 恰好 **5** 条红 —— 五个"没有去处 ⇒ 不是按钮"的半边；`_Pill` 那条正确地仍绿 |
| 同文件六处 `button:` 全写成 `false` | 恰好 **6** 条红（六个"有去处"的半边） |
| `settings_page.dart` 删 `button: true, selected: isFirst` 与「已删除」行的 `button: true` | 恰好 2 条红 |
| `usage_page.dart` 删热力图一格的 `button/selected/label`、胶囊的 `button/selected`、项目头的 `button` | 恰好 3 条红 |

门禁：`dart format` / `dart analyze --fatal-infos` 0、`flutter test` **1881 项**（+13）、
`verify-size` 19 条自检（`chat_turns` 上限 **2000 → 2050**，见下）、
`verify-platform-boundary` 879 项、`verify-rpc-single-caller`、`verify-icons`、`verify-tool-paths`。

## Alternatives considered

1. **给 `Semantics` 加 `hint`（"点一下复制路径" / "点一下展开"）**
   - 最强的理由：把"点了会怎样"也念出来，对差异行那种动作不直观的更友好。
   - 为何被否：本仓没有任何一处用 `hint`（`Select-String "hint:"` 0 处），而按钮 + 可见文字
     已经够表达；引入第二种表达方式会让"什么该念、什么不该念"多一条没人守的口径。
     真要补，该是**一处裁决 + 一条用例**，不是这一批顺手加的几个字符串。
2. **`MergeSemantics` 把整行合成一个节点**（工具卡 / 端点行）
   - 最强的理由：一次停顿念完整行，行内不再有碎节点。
   - 为何被否：已否过一次（`2026-11-10-tappable-semantics.md`）。端点行里有行尾「更多」
     `IconButton`、工具卡展开后正文里还有可点内容 —— 合并会让它们摸不到。
3. **热力图整块一个 `Semantics`（"近 30 天活动热力图"）**
   - 最强的理由：30~90 个格子逐个念太吵。
   - 为何被否：那会给出**没有确定动作**的节点（点哪一格？），同时间轴整条轨道被否的理由。
     一格一个节点至少"哪一格 = 哪一天"，而且数量有界（7/30/90 天）。
     嫌吵时的正解是分档摘要，不是撤掉可达性。
4. **端点行报 `selected: isActive`（"当前连接"）**
   - 最强的理由：「当前连接」是用户最关心的一件事。
   - 为何被否：点这一行改的是**首选**（顺序），不是"当前连接"。把两件事塞进同一个位，
     用户在"首选是 A、当前连的是 B"时会听到自相矛盾的读数。`isActive` 已经由行内文字说清。
5. **把 `chat_turns.dart` 的预算提到 2050 vs 削掉 10 行注释**
   - 最强的理由：棘轮"只降不升"。
   - 为何被否（提到 2050）：这批加的每一行都是"为什么这里要报角色"的判据，删掉就是把
     刚写下的理由再藏回去；棘轮允许"提是一次可见的 diff"（
     `2026-11-10-size-budget-ratchet.md` 的 Consequences），而这一格本来就是"可按条目族分文件"的
     待拆户。真要收窄是**搬走一族**（如命令卡 / 重试行各自成文件），不是压注释。

## Consequences

- 收益：**13 处可点区**第一次对读屏用户有角色；其中 8 处还有条件 ——"点不动的就不报按钮"
  现在是断言而不是注释。
- 收益：热力图那一格第一次有名字。它原本是这个页面上信息密度最高、对读屏用户完全不可达的一块
  （颜色深浅 = 当天用量）。
- 收益：范围胶囊在"页面没接回调"时不再是按钮 —— 一处真实的假入口被关掉（
  `_RangeChip.onTap` 从恒非空变成可空）。
- 代价：`_RangeChip.onTap` 改了形状（可空），调用点从"总是传回调"变成"没回调就传 null"。
  这正是想要的：**没有去处时不装按钮**。
- 代价：`chat_turns.dart` 上限 2000 → 2050（+10 行）。这一格现在是 2050/2050，
  下次动它只有两条路：搬走一个条目族，或再提一次可见的数字。
- 代价：热力图多出的是 `Semantics` 节点，个数 = **点得动的格数**（7/30/90 天窗口，
  未来日期那几格不报角色因为拨不动）。90 天窗口下读屏用户要划过几十格 —— 这是信息的
  真实粒度，不是噪音；要降噪该做"分档摘要"，见上 Alternatives。
- 未做：`count-a11y-candidates.mjs` 报的计数 **57 → 45**（上界，其中至少 2 处是已读过的假阳性）。
  剩下的按同一口径继续按屏推进，别照单改；以及**仍然没有机械门禁** —— "该念成什么"是语义判断，
  做不成规则；防回归靠每屏那条 `isSemantics` 用例。
- 未做：`TakeoverHint` 的 `InkWell` 仍留着（`onTap` 恒 `null`）。删它要改类形状，
  而"以后会不会给它一个去处"没有答案 —— 留着不动比替未来做决定便宜。
