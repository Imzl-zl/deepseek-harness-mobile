# Agent Note: 输入栏与顶栏不再自己垫色带（照 DSH 的分层）

Status: implemented

## Problem

用户 2026-10-19：「然后整个会话页面和输入框背景这一块设计不和谐吧」。
2026-10-20 自查时把范围从"输入栏"扩到"顶栏"——**两处是同一类错**：
给本该与页面同色的东西垫了一条色带。

## 先量（真机像素，不猜）

浅色主题，`System.Drawing` 采样真机截图：

- 输入栏一带（`x=30` 竖向）：
  `#FFFFFF`（会话区）→ **`#F1F3F5`（输入栏外面那条灰带）** → `#FFFFFF`（卡内）
- 顶栏（`x=540` 竖向）：`#F1F3F5`（灰带）→ `#FFFFFF`（会话区）
- 横向另测：页面 `#FFFFFF` / 卡片 `#FFFFFF` / 顶栏 `#F1F3F5`

**两个结论**：① 输入栏外面有一条 `c.sidebar` 灰带；② 顶栏整条是 `c.sidebar` 灰。
而输入栏卡片本身是 `layer1`（亮色下也是纯白）**且没有任何阴影** —— 在白底上隐形。

## DSH 的做法（源码）

### 输入栏（`ui-conversation/src/client/skeleton/InputBar.module.css`）

- `.root`（`:2-11`）**没有声明 `background`** —— 卡片直接坐在页面底色上；
- `.card`（`:45-63`）：
  ```css
  border: 0;                                   /* 描边由 elevation 发丝线画，不占布局 */
  --dsw-elevation-stroke-color: var(--dsw-alias-border-l2);
  background: var(--dsw-specific-input-major);
  box-shadow: var(--dsw-elevation-soft);
  ```
- `--dsw-specific-input-major`：亮 = `neutral-bluish-00`（**也是白**）、
  暗 = `neutral-bluish-850`（`design-platform.css:269,387`）。
  **所以"看得见"完全靠那层阴影，只改底色改不出来。**
- `--dsw-elevation-soft`（`gradient-shadow-text.css:33,38-39`）：
  ```css
  var(--dsw-elevation-stroke),              /* 0 0 0 0.5px <stroke-color> */
  0 4px 16px 0 rgba(0,0,0,0.03),
  0 0 24px  0 rgba(0,0,0,0.03);
  ```
- `--dsw-alias-border-l2`：亮 `rgba(0,0,0,0.1)`、暗 `rgba(255,255,255,0.12)`
  （`:187,305`）。

### 会话顶栏（`ConversationRoot.module.css`）

- `.root`（`:7`）= `background: var(--dsw-alias-bg-base)`；
- `.header`（`:15`）= **只声明** `border-bottom: 0.5px solid
  var(--dsw-alias-border-l3)`（`:22`），**没有任何 `background`** ——
  它与页面同色，靠一条发丝下边线分隔。
- `--dsw-alias-border-l3`：亮 `rgba(0,0,0,0.12)`、暗 `rgba(255,255,255,0.16)`
  （`:188,306`）。
- `--dsw-alias-bg-base` 暗色 = `neutral-bluish-950` = `rgb(21,21,23)`（`:74`）
  —— **与我们的 `DshColors.bgBase` `#151517` 完全一致**。

## Decision

1. `DshColorTokens` 加三个 token（明暗各一份，值与 DSH 逐字一致）：
   `composer`（`--dsw-specific-input-major`）、`borderL2`、
   `borderL3`（`--dsw-alias-border-l3`）。
2. **输入栏外层**底色 `c.sidebar` → `c.bgBase`（去掉灰带；等价于 DSH 的"根无背景"）。
3. **输入栏卡片** `c.layer1` → `c.composer`，并加三层 `boxShadow`：
   - `BoxShadow(color: c.borderL2, spreadRadius: 0.5)` ← 发丝环
   - `BoxShadow(color: 0x08000000, blurRadius: 16, offset: (0,4))`
   - `BoxShadow(color: 0x08000000, blurRadius: 24)`

   `rgba(0,0,0,0.03)` → `0.03×255 ≈ 8` → `0x08`。
4. **顶栏**底色 `c.sidebar` → `c.bgBase`，并加
   `Border(bottom: BorderSide(color: c.borderL3, width: 0.5))`。
   **底色与边线都放 `decoration`**：`Container` 不允许同时给 `color` 与
   `decoration`（`container.dart:277` 的断言，第一版就撞上了）。

## Alternatives considered（否掉的）

- **只给卡片换个底色**（比如浅灰）：DSH 的亮色卡片就是白，靠阴影分层；
  自己发明一个灰会与 `bg-layer-*` 的语义打架，且深色下没有对应物。否。
- **用 `Border.all` 画输入栏描边**：DSH 明确 `border: 0`，描边走 elevation
  发丝线（"不占布局"）；Flutter 里用 `spreadRadius: 0.5` 的零模糊阴影等价。
  否（选了更贴 DSH 的那个）。
- **顶栏保留灰带、只把输入栏修好**：那样顶部灰 / 中间白 / 底部白，割裂更明显。
  两处必须一起改 —— 它们本来是同一条视觉规则的两端。否。

## Consequences

- 收益：整页变成**一个连续的白色表面**（顶栏白 + 发丝线、会话区白、
  输入栏是浮着的白卡）；深色下同理。这是 DSH 的分层方式。
- 代价：`DshColorTokens` 多三个字段（6 处构造点跟着改）；
  输入栏外层与顶栏都不再用 `sidebar` 色（`sidebar` 仍用于抽屉 / 设置 / 配对页，
  那些确实是"侧栏表面"，语义没变）。
- **真机像素证据（浅色，改后）**：
  - 输入栏：从页面白平滑落到
    `#FEFEFE → #FDFDFD → #FCFCFC → #FBFBFB → #FAFAFA → #F3F3F3 → #E6E6E6 → #DFDFDF`
    （y=2058..2124），正是 `elevation-soft` 的两层模糊；`#F1F3F5` 灰带消失。
  - 顶栏：`#FFFFFF`(60..248) → `#F7F7F7`/`#E0E0E0`(249..250，发丝线) →
    `#FFFFFF`(251..479)。`#E0E0E0` 正是 `rgba(0,0,0,0.12)` 叠在白底上
    （`255×0.88 = 224 = #E0`）—— 与 token 值精确吻合。
- **真机像素证据（深色，改后）**：输入栏一带
  `#151517`（页面）→ `#1B1B1D / #29292B / #303032 / #2F2F31`（发丝环 + 阴影，
  y=2121..2125）→ **`#2C2C2E`**（卡内，= `composer`，y=2126..2296）→ 对称落回。
  深色下灰带同样消失。
- 测试：`flutter test 841` 全绿（纯视觉改动，布局判据未变；
  输入栏三条硬规则的判据仍在 `composer_layout_test.dart`）。
