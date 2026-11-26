# Agent Note: 宽表横向滚动条压住最后一行 —— 安全区不许漏进 Markdown 内部

Status: implemented

## Problem

用户 2026-11-26 原话：

> 会话渲染的一个表格视图，左右滚动的滚动条位置不对，不在最下面，和最后一排字有点重叠了

只在**宽表**（需要横向滚动）上出现，且**底部安全区越高的机器越明显**：
手势导航条 48 → 条压进内容近 48px；iOS Home 指示条 34 → 同样压住。

## 根因

不是我们画的条，也不是配色 —— 是 `MediaQuery` 的安全区被
**表格内部那层 `Scrollbar` 当成自己的 padding** 吃掉了。

1. `flutter_markdown_plus` 给宽表套一层 `Scrollbar`
   （`flutter_markdown_plus-1.0.12/lib/src/builder.dart:453-463`），只在
   `tableColumnWidth` 是 `IntrinsicColumnWidth` / `FixedColumnWidth` 时才套 ——
   我们为了"自然宽度 + 横滚"正是这么选的。
2. 那个 `Scrollbar` 是 Material 的，它把
   `..padding = MediaQuery.paddingOf(context)` 直接写进画笔
   （`packages/flutter/lib/src/material/scrollbar.dart:360`）。
3. 画笔把 padding 用在**三个**地方（都在
   `packages/flutter/lib/src/widgets/scrollbar.dart`）：
   - `:610` 横向条 y = `size.height - thickness - crossAxisMargin - padding.bottom`
   - `:603` 横向条 x 起点 = `padding.left`
   - `:408,413` 轨道长 = `viewportDimension - padding.horizontal`

**这不是 Flutter 的 bug**：`padding` 的文档明说它的用途是
"typically set to `MediaQueryData.padding` to avoid partial obstructions such as
display notches"（`:293-296`）—— 但那个前提是**滚动条贴着屏幕边缘**。
我们的滚动条永远在**内容流内部**（表格在消息列表里，列表下面是输入栏），
不满足这个前提，于是这份为"屏幕边缘"准备的避让被错误地施加到了内容内部。

实测（盒子 368×140、Table 底边 148）：

| 安全区 | `pad` 被读到 | 条位置 | 后果 |
|---|---|---|---|
| 无 | `EdgeInsets.zero` | y=153 | 正常 |
| bottom 48 | **bottom=0**（修复后）| y=153 | 正常 |
| bottom 34（修复前）| bottom=34 | **y=119** | 压住最后一行 29px |
| left 44 | left=44 | 条右移 44、轨道短 88 | 与表格左缘错位 |
| 四边 | left/right 漏进来 | 右移+缩短 | 错位且变短 |

## Decision

`DshMarkdown.build` 对整棵 Markdown 子树
`MediaQuery.removePadding(removeLeft/right/bottom: true)`，
并把 `tablePadding.bottom` 从 4 提到 8（条高 3 ⇒ 与表格底边净空 5）。

## Alternatives considered

1. **只加大 `tablePadding.bottom`（不改 MediaQuery）**
   - 最强的理由：一处改动，不需要怀疑依赖代价。
   - 为何被否：这是**掩盖**。inset=48 就要加 48px 留白才能把条推出去，
     在没 inset 的机器上平白多一条空带；而且它完全不解决 `left/right`
     导致的错位（那一半是位置问题，加高底部永远修不到）。
2. **给那层 `Scrollbar` 传 `padding: EdgeInsets.zero`**
   - 最强的理由：直击成因，影响面只在一个 widget。
   - 为何被否：`padding` 不是 `MarkdownStyleSheet` 的字段，包也没透传
     （`builder.dart:454-455` 只给了 `thumbVisibility`）—— 要传就得 fork 包，
     或接管 `builders['table']` 自己重写整张表（列宽/边框/单元格全重做）。
3. **接管 `builders['table']`**
   - 最强的理由：`table` 确实可以被 `builders` 接管
     （`builder.dart:403`：`builders[tag]?.visitElementAfterWithContext(...) ?? defaultChild()`）。
   - 为何被否：接管意味着自己重建表格渲染（`_buildTable` 那一整套），
     为了一个 padding 复制几十行包内逻辑 —— 维护成本远高于收益。
4. **改回 `FlexColumnWidth`（不套 Scrollbar）**
   - 最强的理由：问题源头消失，零新增代码。
   - 为何被否：等于删掉"宽表横向滚动"这个功能，宽表会被压成窄列。
5. **不用 `removePadding`，改用 `ScrollbarTheme` 把 `crossAxisMargin` 调负**
   - 最强的理由：也在主题层收口。
   - 为何被否：`crossAxisMargin` 是**加**进公式的（`:610` 里是减
     `crossAxisMargin`），调负只会让条往下超出盒子被裁掉，而 `padding.bottom`
     是屏幕给的，每台机器不同，主题里没有它的值。

## 二阶 / 三阶影响（都实测过）

1. **性能：`removePadding` 会不会让每条消息随键盘重建？**
   - 它是 `MediaQuery.of(context)`（二者都 aspect=null，
     `media_query.dart:1174`），语法上等于"整份依赖"，看起来会。
   - 实测（`const` 子树 + 逐项改 `MediaQueryData`，数 `DshMarkdown.build`）：

     | 变更 | Markdown build |
     |---|---|
     | 挂载 | 1 |
     | 键盘（viewInsets）| **1（不重建）** |
     | 安全区（padding）| 2 |

   - 结论：**只有安全区变化才重建**，键盘不重建。安全区在一次使用里几乎不变
     （手势条常驻），所以这条代价可忽略。
   - 教训：这条我第一次测时**测错了**（见下"测试自身的坑"），差点据此
     去改 `chat_turns.dart` 里一条本来正确的注释。
2. **把 `chat_turns.dart` 的 `sizeOf` 注释也"更正"掉 —— 错了，已回退**
   - 我一度实测出"`of` / `paddingOf` / `sizeOf` 三种读法重建次数恒等"，
     于是改了那条注释。那是探针缺陷（每轮 new widget，测的是父级重建）。
   - 用 `const` 子树重测后：键盘变化时 `of` 重建、`paddingOf`/`sizeOf` **不**重建；
     安全区变化时 `of`/`paddingOf` 重建、`sizeOf` 不重建。原注释正确。
   - 现在那条注释里留了复核表，并写明"第一版探针得出过错结论"。
3. **为什么是整棵子树而不是只包表格**：代码块用的是同一个 `Scrollbar`
   （`builder.dart:357-364`），同一条病，只修表格会留下第二份规则。
4. **左/右也一并去掉**：横屏刘海 44 会让横向条右移 44、缩短 88（实测表）。
   只去 bottom 是修了一半 —— 这是我第一版的真实缺陷。
5. **`viewPadding` 也被改了**：`removePadding` 同时下调 `viewPadding`
   （`media_query.dart` 的 `removePadding` 实现）。Markdown 子树里没有读者
   （包内只读 `textScalerOf`，`_functions_io.dart:102`），无影响。
6. **没有别的滚动条受影响**：全仓 `Scrollbar` 只有包内这一处（grep 实测），
   我们自己不画滚动条，所以"去掉安全区会不会让条被刘海挡"不成立 ——
   我们的条不在屏幕边缘。

## Consequences

- 收益：四个方向的 insets 都不再干扰 Markdown 内部横滚；宽表条固定在
  滚动盒子底部并与内容左右对齐。
- 代价：Markdown 子树里拿不到 `padding`（含 `left/right/bottom/top` 未动 top）。
  将来若真有读者，得从上层显式传 —— 这也正是期望的形式。
- 代价：表格底部净空 4 → 8（多 4px），代码块未动（它的条只在拖动时出现）。

## 回归网

`app/test/markdown_table_scrollbar_inset_test.dart` 五条（bottom48 / bottom34 /
lr44 / 四边 / 无）：从 `RawScrollbarState.scrollbarPainter` 的公开 getter
按上面 `:610,603,408` 三个公式算条的位置，断言
`barTop >= 表格底边 + 4`、`barLeft == 盒左缘`、`barWidth == 盒宽`。

变异校验（逐项做，都红）：

| 变异 | 红在哪 |
|---|---|
| `removeBottom: false` | inset 48 条在 105、inset 34 条在 119 |
| `removeLeft: false` | `barLeft=60` vs `boxLeft=16` |
| `removeRight: false` | `barWidth=324` vs `boxWidth=368` |
| `tablePadding.bottom` 改回 4 | 条顶 149 vs 表格底 148，净空 1 |

## 测试自身的坑（值得记住）

1. **基准要选在改动真正生效的那一层**：第一版只用 `Table` 底边比 `barTop`，
   "把 `tablePadding` 改回 4"**没有红** —— 因为 `tablePadding.bottom` 是外层
   滚动视图的 padding、不在 Table 内，`barTop` 仍大于 Table 底边。必须断言
   `barTop - 表格底边 >= 4` 才真正量到留白。
2. **`const` 子树才测得到依赖**：数重建次数时若每轮新建 widget，
   测到的是"父级重建"，三种 `MediaQuery` 读法会显示成完全等价（假象）。
3. **私有 State 不能跨库强转**：`tester.state()` 拿到的是
   `_MaterialScrollbarState`，`as` 成自定义 interface 会 `is not a subtype`；
   `byType(RawScrollbar)` 也不命中（实际是子类）。用
   `byWidgetPredicate((w) => w is RawScrollbar)` + 一处 `dynamic` 读公开字段。
