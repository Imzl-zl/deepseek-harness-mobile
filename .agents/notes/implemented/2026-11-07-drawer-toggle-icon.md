# Agent Note: 顶栏开抽屉用 `☰`（自画），不用 DSH 的 `panelLeft`

Status: implemented

## Problem

真机（2026-11-07）：会话页左上角那枚图标"有点丑"，想要主流一点。

那枚用的是 DSH 的 `panelLeft`（16px 的圆角方框 + 一条竖线）。在桌面上它是"折叠侧栏"，
到了手机上：抽屉里装的是**会话列表**，而 24dp 下的方框+竖线读起来就是一个空方框，
认不出"点它会出去一张列表"。

而设计基线里这一格写的本来一直是 `☰`（`docs/design-and-tech-plan.md:44,222`、
`dsh_app_bar.dart` 顶部的线框图）。也就是说实现与基线早就分开着 —— 这次是回到基线。

## Decision

1. 自画三横线（`app/lib/ui/dsh_menu_glyph.dart`），**不进图标表**：
   `theme/dsh_icons.dart` 是机生成文件（DSH → 原型 `icons.js` → Dart），
   手写进去下次抽取就没了；而 DSH 的图标集里**没有** `☰`（`panel-left-outline` 是它的侧栏语义）。
2. 尺寸与线宽照图标集的规矩：16 的坐标系、线宽随尺寸等比（`size × 1.5 / 16`，20dp 时 1.875）。
3. 原型同一个按钮换成同一组坐标的 inline SVG（`mock/proto/index.html`），
   不再走 `data-icon` —— 两边的形状与坐标一致，只是载体不同（DOM / CustomPaint）。
4. `DshAppBarButton` 增 `glyph`：图标名仍要合法（图标表的判据不松），有 `glyph` 就画它。

## Alternatives considered

1. **换成图标集里的 `flatList`（三行 + 圆点）**
   - 能马上用、零新增代码；实际渲染过：24dp 下三个圆点像碎屑，而且"列表"读起来像
     "清单"而不是"开抽屉"。`☰` 才是移动端开抽屉的主流形态。
2. **把 `☰` 加进 `theme/dsh_icons.dart`**
   - 为何被否：那是生成物；要么手改被下次抽取抹掉，要么给抽取器加"app 自备字形"
     的旁路 —— 为了一枚字形引入第二套来源，比自画一个 20 行的 painter 更贵。

## Consequences

- 这枚字形**不在** `DshIcons.names` 里：任何"图标名必须来自图标集"的机械校验都照旧成立；
  它在 `dsh_app_bar.dart` 里以 `glyph` 注入，用错名字仍会红。
- 判据：`app/test/drawer_toggle_glyph_test.dart`（顶栏画的是这枚字形 + 点了会回调），
  并做过变异校验（把 `glyph` 去掉，用例红）。
- 成本如实记：两个载体（Dart painter / 原型 inline SVG）共享同一组坐标 ——
  改形状要同时改两处，注释里都写了对方的位置。
