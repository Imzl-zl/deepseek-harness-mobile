# Agent Note: 阅读位置与流式重排成本（下一批的设计）

Status: proposed

## Problem

两条事实，都是 2026-11-07 在本机量的，不是推测：

1. **倒序列表里"最新端"一变，阅读内容就整体位移。**
   夹具：`ListView.builder(reverse: true)`，每格 100 px，滚到 `pixels = 600` 后
   在最新端插入一格，锚点格从屏幕 y=40 走到 y=−60 —— **位移恰好等于插入格的高度**。
   流式尾条目的增长、以及"虚拟尾换成持久条目"都发生在同一端。
2. **流式尾条目每批整段重排。** 同一段 4 KB 中文+列表+行内代码，
   `MarkdownBody(selectable: true)` 单帧 303 ms、`selectable: false` 33 ms
   （flutter_test 的 debug 绑定；绝对值不代表 release，比例与形状可用）。
   选择器已在
   `implemented/2026-11-07-live-message-shape.md` 那一批关掉，剩下的成本是
   O(正文长度) 的解析 + 排版。

## Proposed decision

### 1. 阅读位置：由滚动位置自己补偿，不新增"为什么变了"的判断

新增 `ReadingPreservingScrollPosition`（`ScrollPositionWithSingleContext` 的子类，
经 `ScrollController.createScrollPosition` 注入 `_ConversationFlow`），实现 SDK 的
`correctForNewDimensions(ScrollMetrics old, ScrollMetrics neu)`
（`D:\soft\flutter\packages\flutter\lib\src\widgets\scroll_position.dart`：在
`applyContentDimensions` 里改 `pixels` **必须**走这个钩子，否则框架断言直接抛）。

修正量取**锚点条目的滚动偏移变化**：

- 锚点 = 当前第一条可见条目（`_firstVisibleIndex` 已经在算它）；
- 偏移 = `RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset`；
- 偏移变了多少，`pixels` 就补多少；
- `pixels == 0`（贴最新端）不补 —— 那时框架本来就钉在最新。

如此不需要区分"插入还是增长""在上方还是下方"，也不需要给翻页打标记：
**改的是"读者看着的那条原来在哪、现在在哪"这件事本身**。

### 2. 流式块级冻结：这一批不做，先量

DSH 的做法是 `ui-primitives/src/markdown/incremental.ts` 的
`UNSTABLE_TAIL_BLOCKS = 2`：块级解析，除末尾两块外全部冻结成不可变子树。
Dart 的 `markdown` 包**不给块偏移**（`md.Element` 没有 `position`），要照做就得自己
切块 —— 那是一个独立批次（引用定义、列表跨空行续行、表格都是切错的来源）。

判据先立好：真机 `flutter run --profile` 跑一条长回答，看流式期间
build+layout 是否超过 ~4 ms/帧（60 fps 的掉帧门槛是 8 ms）。不超就不做。

## Alternatives considered

1. **`CustomScrollView(center:)` 两侧分栏**
   - 量到：插入与增长都不动阅读位置（140 → 140 → 140）。
   - 为何不选：最新侧的边界必须随轮次推进而移动，跨边界搬迁同样会顶走读者；
     而 `_firstVisibleIndex`、跳转钮、翻页锚点都要按两侧下标重写。
2. **阅读时冻结底部更新**（不渲染新批）
   - 几何上最省，但尾条目半可见时屏幕会停住 —— 桌面是持续渲染、只保位置，两边会不一致。
3. **用 `ΔmaxScrollExtent` 补偿**
   - 分不清"最新端增长"与"更旧端翻页插入"：两者都改 `maxScrollExtent`，
     翻页时会把读者往下推一整页。
4. **10 Hz 节流**
   - 产品行为变更（字一顿一顿地出），用户没要求。

## Open verification

- 1 的验收：widget 用例（倒序列表、离底时插入／增长、贴底时插入），断言锚点屏幕
  坐标与 `pixels` 同时成立；再用同一条夹具钉住"贴底时新内容可见"。
- 2 的判据：真机 profile 的帧时间；不达标才动。

## Consequences

- 滚动位置多一层子类，`_ConversationFlow` 的控制器要自己建（`createScrollPosition`），
  贴着 `chat_jumper` 与 `load_older` 的坐标假设走一遍。
- 锚点取不到（条目还没布局 / 被移出窗口）时**不补**：那是"不知道"，不是"猜一个 0"。
