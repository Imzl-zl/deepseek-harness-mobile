# Agent Note: `chat_page.dart` 收窄第二批 —— 改动卡与轨迹页签整块搬走

Status: implemented

## Problem

`ui/chat_page.dart` 上一批把文件面板搬走之后是 **4762 行 / 上限 4800**
（`implemented/2026-11-12-chat-page-files-pane-move.md`）—— 只剩 **38 行**余量。
那是棘轮"降了一格"之后的样子，而这一批要证明的不是"还能不能再拆一个 widget"
（拆 widget 不减页面那一行），而是**下一块面在哪**：

| 原位置 | 是什么 | 行数 |
|---|---|---|
| `_ChangedFilesCard` + `_ChangedFilesCardState`（`:4117`） | 会话流里那张「已编辑 N 个文件」卡 | 227 |
| `_TrajectoryTab` + `_TrajectoryTabState`（`:4548`） | 轨迹页签的装配（三态 + 进入即重读 + 空态） | 97 |

两块都被上一批笔记点过名，但**没回答"它和谁同族"**。这次各回答一次，答案不一样。

## Decision

### 1. 改动卡 → **新文件** `app/lib/ui/changes_card.dart`

它与 `ui/files_pane.dart` 读同一份 `file.changes`、共用 `diffCountsOf`，看起来同族；
但**物理位置不同** —— 这张卡是**会话流里的条目**（参与消息列表、轮组与事件投影），
文件面板是**右抽屉里的一块**。上一批就是按这条理由拒过"顺手搬过去"，这次搬走它
也不改变那个事实；而且并进 `files_pane.dart` 会把那个文件顶到 **811 行**（默认上限 800），
于是它马上也得进预算表 —— 为了"少一个文件"换来"多一格预算"，不划算。

`diffCountsOf` 继续住在 `files_pane.dart`（它是上一批从 chat_page 搬过去的），
新文件 `import 'files_pane.dart' show diffCountsOf;` —— 共用事实仍只有一份，
而"改动卡与侧栏会不会飘成 +9 / +0"那条注释跟着 `diffCountsOf` 留在原处。

### 2. 轨迹页签 → **`ui/trajectory_page.dart`**（不是新文件）

它做的事就是"把 `turnOutline` 与本会话条目 join 成轮次行 + 进入即重读"，
而被 join 的那一半（`buildTraceTurns` / `TrajectoryTab` / 空态三态）全在
`trajectory_page.dart`。**接线与行规格是同一屏的两半**，分居两个文件时
"这一屏怎么装配"要跳两处才读得完 —— 搬过去之后就一处。
搬完那个文件 **772 行**，仍在 800 行默认上限内，不进预算表。

### 3. 改名只发生在私有 → 公有这一层

| 原 | 现 | 为什么 |
|---|---|---|
| `_ChangedFilesCard` / `_ChangedFilesCardState` | `ChangedFilesCard` / `ChangedFilesCardState` | 跨库引用不了私有名 |
| `_TrajectoryTab` / `_TrajectoryTabState` | `TrajectoryTabHost` / `_TrajectoryTabHostState` | `TrajectoryTab` 那个名字**已经被占用**（纯展示的轨迹页）；`Host` 后缀与 `UsagePageHost` 同一口径：`Host` = 装配层，`State` 仍私有（外面不需要） |

注释按"为什么这样写"整块带走：卡的三态与"数字来自电脑"、轨迹页
「为什么之前常驻空态」「为什么进来要重读一次投影」原样跟着各自的类。
`TrajectoryTabHost` 的文件头加了一段「它原来在 `chat_page.dart` 的哪一段、为什么搬」。

### 4. 收紧就是本批的产物

`app/tools/verify-size.mjs` 的 `chat_page.dart`：**4800 → 4450**（`ceil(实测 4422, 50)`）。

## 准入判据

| 判据 | 结果 |
|---|---|
| `cd app; flutter test` | **1881 项全绿，用例零改动**（这是"只搬不改行为"的主判据） |
| `dart analyze --fatal-infos lib test integration_test` | 0（搬完暴露一个 unused `../model/changes.dart`，一并删掉） |
| `dart format --set-exit-if-changed` | 0 |
| `git diff -w app/lib/ui/chat_page.dart` | **插入只有 3 行**：`import 'changes_card.dart'` 与两处改名；其余 343 行全是删除 |
| `cd app; flutter test test/changes_card_test.dart` | 21 项原样通过（卡的五条判据：标题用 `total`、行用 `display`、二进制是宿主标记、点行 `file.read`、`{summary:null}` 不画卡） |
| `node app/tools/verify-size.mjs` | 19 条自检 + **chat_page 上限 4450** |
| `node app/tools/verify-platform-boundary.mjs` | 885 项（多扫一个 `changes_card.dart`，规则数不变） |
| `node app/tools/verify-rpc-single-caller.mjs` | 全绿（搬移没有引入 `call<`） |

**没有变异校验**：这一批不改行为，删/改判据都会让搬移失去意义。它的判据是
"用例一条都不许改、且全绿" —— 一个行为被搬丢时，1881 项里总有一条会红，
而那条红**必须靠改代码解决，不许改用例**。

## Alternatives considered

1. **改动卡并进 `ui/files_pane.dart`**
   - 最强的理由：共用 `diffCountsOf` 与同一份 `file.changes`，放在一起最短。
   - 为何被否：**物理位置不同**（会话流条目 vs 右抽屉面板），而那个文件会涨到 811 行 ——
     立刻要进预算表。等于用"少一个文件"换"多一格预算"，把棘轮往松的方向推一格。
2. **`part` / `part of` 共享同一个 library（零改名）**
   - 最强的理由：不用把两个类改名成公有。
   - 为何被否：本仓零 `part`（上一批已写过同一条），为一个搬家引入新的文件关系，
     代价是以后每个读 `ui/` 的人都要多认一种。
3. **把 `_EmptyChat` / `_SessionListInline` / `RunningBar` 一起搬**
   - 最强的理由：一次搬够了，余量更宽。
   - 为何被否：这批的判据是"搬一块**自洽**的"（上一批的纪律），而那两个不构成一整块面 ——
     `_EmptyChat` 与 `_LandingLoading` 是同一组"没有内容时说什么"的文案，
     它们该一起走或都不走；`RunningBar` 与底部预算（`_BottomBudget`）绑着。
     一次搬两块已经把 4450 定下来了，够了。
4. **先搬、上限不动（还写 4800）**
   - 最强的理由：`budget-not-stale` 只在"瘦了却没改表"时红；留着旧数字不会红。
   - 为何被否：`budget-not-stale` 恰恰会红（`4800 > ceil(4422, 50)`）。而且"能降就降"
     是这格棘轮唯一的意义 —— 上批笔记里就写了"提上限是可见的债，这一次能降就该降"。

## Consequences

- 收益：`chat_page.dart` **4762 → 4422 行**，上限收到 4450。**余量 38 → 28** ——
  仍然只够加一小段，所以下一批还是"搬一块面"，不是"再拆一个 widget"。
- 收益：轨迹页从"接线在这、行规格在那"变成一处读完；改动卡单独一个文件，
  它那张卡的注释（三态 / 数字从哪来 / 标题点开的是什么）不再埋在 4700 行里。
- 代价：`ui/` 多一个文件（`changes_card.dart`，274 行）与两个公有名；
  `verify-platform-boundary` 的项数 879 → 885（多扫一个文件 × 若干规则，口径正常变化）。
- 代价：`TrajectoryTabHost` 这个名字里 `Host` 与 `UsagePageHost` 同义但不同层
  （那个是页面宿主 + 路由，这个是页签装配）。**没有统一成 `…Host` 的抽象** ——
  两个东西只有"都不是纯展示"这一个共同点，抽一层只会多一次跳转。
- 未做：`ChangedFilesCard` 的**行与标题仍是手写 `InkWell`，没有按钮角色**
  （`count-a11y-candidates.mjs` 现在把它们报在 `changes_card.dart` 里）。
  这批是"只搬不改行为"，a11y 另起一批 —— 与 `files_pane.dart` 那两行当时的顺序一致。
- 未做：`chat_page.dart` 仍是 4422 行。真正的收窄还剩两处候选：
  `_EmptyChat` + `_LandingLoading`（"没有内容时说什么"一组）、
  `_BottomBudget` 绑着的底部那一列（接管卡 / 目标条 / 排队条 / 输入栏 / 统计条）。
