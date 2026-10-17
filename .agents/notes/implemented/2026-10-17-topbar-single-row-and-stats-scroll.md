# Agent Note: 顶栏收成一行（计数 chip 进顶栏）+ 统计条改单行横滚

Status: implemented

## Problem

用户 2026-10-17 真机反馈（原话）：

> "APP 最下面的状态换行了，我知道这个确实信息多，手机小，这个你看看能不能字体，间距在
> 不影响观看的情况下再小点，两边距再小点……上面的子智能体和后台任务我看再下面不是顶栏，
> 这样也行，就是咋看着不是很好看，顶栏的会话名字和图标能不能在不影响观感的情况再小点，
> 然后名字占少点，这个子智能体，后台任务放顶栏，实在勉强这样也行啊"

两件事各自的现状：

1. **统计条**（输入卡片下方）是 `Wrap`：三项读数的宽度都随数字变，放不下就换行。
   真机截图（1080×2400 @420dpi = **411.4dp 宽**）上 `◔ 42%` 掉到了第二行。
2. **子智能体 / 后台任务**走 `_LiveChipsRow`，占顶栏之下、分段控件之上的**一整行**。
   而且那一行的 `Column` 没写 `crossAxisAlignment`（默认 `center`），`Wrap` 又会收缩到
   内容宽 —— 结果只有一枚 chip 时它**悬在屏幕中间**，这就是用户说的"看着不是很好看"。

Flutter 实测（`app/test/stats_bar_layout_test.dart` 的测量值）：

| 读数 | 整枚 chip |
|---|---|
| `第 5 轮 · 70 步 · 77 tok/s` | 292.8dp |
| `18.2M tok · 缓存命中 94%` | 259.0dp |
| `◐ 42%` | 68.8dp |
| **合计**（含两处 6dp 间距） | **632.6dp** |

可用宽度 = 411.4 − 16（外层 padding）− 4（条内 padding）= **391.4dp**。**差 237dp。**

顶栏那边（`live_chips_row_test.dart` 的测量值，该文件已被 `topbar_chips_test.dart` 接替）：
顶栏固定占位 `☰ + ● + ⊕` 等共 **126dp**，留给「标题 + chip」**285.4dp**；
而 DSH 那种**全文本** chip 单枚 `3 个子智能体` = **137.8dp**、`2 个后台任务运行中` = **174.5dp**。

顺带查出一处**真的文案偏离**：DSH 中文原文是 `{turns} 轮 {steps} 步`
（`ui-chat/src/client/locale.ts:77` 的 `stats.counts`），电脑端此刻显示的就是
`5 轮 73 步 · 77 tok/s`；手机写的是 `第 5 轮 · 70 步` —— 多一个「第」和一个 `·`，
同一个会话在两端是两个字符串（`session_stats.dart` 的注释本来就写着正确的形态，代码没照它写）。

## Decision

1. **统计条改单行 + 横向滚动**（用户在三个选项里明确选的那条："下面滚动条的形式懂吧？
   就一行，超出得可以滚动查看明白不？点击不受影响啊"）。
   `Wrap` → `SingleChildScrollView(scrollDirection: horizontal)` 包一个 `Row`。
   `_StatChip` 里的 `Flexible` 同步删掉 —— 横滚容器给的是**无界宽度**，
   `Flexible` 在那里会直接抛 `RenderFlex children have non-zero flex but incoming width
   constraints are unbounded`；而"放不下"这件事已经归滚动管了。
   点击不受影响：横滑由拖动的识别器接管，原地按一下仍归 chip 的 `InkWell`
   （`stats_bar_layout_test.dart` 有两条真点的用例钉住）。
2. **轮次格文案改回 DSH 原文** `{turns} 轮 {steps} 步`（去掉「第」与多余的 `·`）。
   字数不是重点（只省约 20dp，填不平 237dp），重点是**同一个会话两端必须是同一个字符串**。
3. **顶栏收成一行**：
   - 标题 `14px → 13px`、上限 `220px → 140px`（形态照 DSH 的 `.crumb`，
     `ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`，手机收窄一档）；
   - 顶栏按钮的图标 `18 → 16`（触摸目标仍是 38×38，不动命中区）；
   - **计数 chip 进顶栏**，与标题同一行 —— DSH 本来就是这么放的
     （`ConversationSession.tsx:127-129` 的 `conversation.session.header.actions`，
     由 `ui-subagent` / `ui-agent-preset` / `ui-jobs` 注册）；
   - chip 取**图标 + 计数**（每枚约 50dp），全文本那句（DSH 原文）退进 **aria/tooltip**。
     411.4dp 上的账：`126 + 140 + 100 ≈ 366`，留约 45dp 余量。
   - 那一整行 chip 撤销，`_LiveChipsRow` 与 `_LiveChip` 删除（连带省下约 34dp 对话高度）。
4. **三个纯文案函数移到 model 层**（`subagentChipLabel` / `subagentChipAria` /
   `jobChipLabel` → `app/lib/model/chat_item.dart`）：顶栏与页面都要用同一份说法，
   留在 `chat_page.dart` 里会让 `dsh_app_bar.dart` 反向 import 页面（循环依赖），
   而 `chat_item.dart` 本来就是 `connectionLabel` / `endpointKindLabel` 这类函数的家。
5. **顺带修掉重复计算与第二个来源**：`_mainScaffold` 里 `_subsFor()` / `_jobsFor()` 原来
   被调 4 次（drawer 两处、chip 行两处），且 chip 行用的是 `_jobsSid`（`currentSid ?? ''`）
   而 drawer 用参数。现在各算一次；`_jobsSid` getter 删除。

## Alternatives considered

- **保持 `Wrap`（换行）**。最强理由：读数一个都不少，且不需要用户学"这里能滑"。
  为何被否：**"哪一项掉到第二行"随数字漂** —— 同一个会话里统计条时高时低（1 行 / 2 行），
  看起来像布局坏了；用户也点名说这个形态不好看。换行只是把"排不下"从裁切换成了抖动。
- **只缩字号 / 间距（用户最初的提议）**。最强理由：改动面最小，不动结构。
  为何被否：**实测填不平**。11px→10px 省约 47dp、内边距 9→6 省 18dp、图标 12→11 省 6dp，
  全做完仍要 **566dp** > 391.4dp。差的 237dp 不是"再小一点"能解决的量级。
- **砍掉一项读数**（我给的 A/B 两个选项：留「轮次/步数/速率 + 上下文环」或
  「token 用量 + 上下文环」，各约 345dp / 334dp，确实一行放得下）。
  最强理由：一行放得下是结构性解决，不引入"可滚动但看不全"的隐式代价，且这是 DSH
  自己的 `简洁` 档语义（`StatsPills.tsx:242,291-293`）。
  为何被否：用户选的是"一行 + 可滚动" —— 要的是**信息全 + 不换行**，不是"少一项"。
- **顶栏放 DSH 的全文本 chip**。最强理由：与 DSH 逐字同形，用户不必猜图标含义。
  为何被否：算过宽度账 —— 两枚 320dp，顶栏留给「标题 + chip」的只有 285.4dp，
  标题会被压到没位置；即使把标题上限降到 140 也只放得下一枚。
- **chips 留在自己那一行（现状），只修居中**。最强理由：不动顶栏，改动面小，
  且全文本可读 —— 这正是 2026-10-16 写进设计文档的"有意偏离"。
  为何被否：① 用户明确说"放顶栏，实在勉强这样也行"；② 那一行在竖屏上白占约 34dp
  对话高度；③ 当年否掉"与标题同一行"的前提是**全文本** chip（250dp 级），
  换成图标 + 计数后那个前提不成立了 —— 这是"前提变了，结论跟着变"，
  不是推翻当年的论证。
- **把上下文环搬进输入卡控制行**（那里有约 120dp 空闲）。最强理由：控制行本来就有空位，
  统计条少一项就少一份宽度压力。
  为何被否：实测剩下两项仍需 `292.8 + 6 + 259 = 557.8dp`（改成 DSH 原文后 528.8dp），
  依然超过 391.4dp —— **解决不了换行**，只会把问题挪个位置。

## Consequences

- 收益：统计条在 411.4dp / 360dp 上都是**一行**，且三项读数都滑得到；顶栏是一行，
  省下约 34dp 对话高度；轮次格与 DSH Web 同一个字符串；`_subsFor`/`_jobsFor` 每帧从 4 次变 1 次；
  `「顶栏就是一行」` 这条现在有断言钉住（`topbar_chips_test.dart` 比纵向中心，比较的是
  标题与 chip 的中心 dy，不是"看起来在一起"）。
- 代价：① 统计条在窄屏上**默认看不全** —— 用户要多滑一下才看到上下文百分比，
  这是"可到达"与"一眼可见"之间的取舍，**由用户明确选择**；
  ② chip 不再显示中文全文本，只有图标 + 数字，含义要靠 aria/tooltip 与图标本身
  （触屏没有 hover，长按才出 tooltip）；
  ③ 标题可见字数变少（190px → 140px 上限）。
- 观测点：`app/test/topbar_chips_test.dart`（真机宽度下 chip 在顶栏、与标题同行、
  标题与分段控件之间不再夹一行、0 时整枚不占位）；`app/test/stats_bar_layout_test.dart`
  （411/360 一行、第三项滑得到、滑动之后点击仍生效）；
  `app/test/widget_test.dart` 的「顶栏标题限宽与计数 chip 的席位」一组；
  原型侧 `mock/proto/tools/verify-proto.mjs` 新增 13 项断言（此前它只采 JSON、从不断言）。
- 被取代的旧篇（**结论不改，只标注**）：
  - `.agents/notes/archived/2026-10-16-topbar-connection-dot-and-title-cap.md`
    的决定 3（标题 220/14）、决定 4（计数另起一行）与备选 3（否掉"chip 进顶栏"）。
  - `.agents/notes/archived/2026-10-17-stats-bar-aligns-web-and-real-sheets.md`
    的决定 3（`Row` → `Wrap`）。
- 仍有代价未解：`_StatChip` 的 `Text` 现在**没有省略号兜底**（无界宽度下不会触发），
  系统大字缩放到极端时单个 chip 会比屏还宽 —— 表现是"多滑两下"，不再是"被裁掉"。
