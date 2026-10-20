# Agent Note: 输入栏从"灰带里的白卡"改成 DSH 的浮卡（elevation-soft）

Status: implemented

## Problem

用户 2026-10-19：「然后整个会话页面和输入框背景这一块设计不和谐吧」。
2026-10-20 追问确认「输入栏背景」那一处。

## 先量，再改（真机像素，不猜）

用 `System.Drawing` 采样真机截图（浅色主题），`x=30` 竖向扫描：

| 区间（物理 px） | 颜色 | 是什么 |
|---|---|---|
| 1600–2078 | `#FFFFFF` | 会话区 |
| **2080–2124** | **`#F1F3F5`** | **输入栏外面那条灰带** |
| 2126–2294 | `#FFFFFF` | 卡片内部 |

横向另测：页面 `#FFFFFF` / 卡片 `#FFFFFF` / 顶栏 `#F1F3F5`。

**所以那处"不和谐"是两件事叠起来的**：
1. 输入栏垫了一条 `c.sidebar` 灰带（`#F1F3F5`）—— 底部像一个
   **独立的栏**，与上面的会话区断开；
2. 卡片本身是 `c.layer1`（亮色下也是纯白）**且没有任何阴影** ——
   在白底上是一块看不出来的白。

## DSH 的做法（源码）

- 输入栏的根 `.root` **没有声明背景**（`ui-conversation/src/client/skeleton/
  InputBar.module.css:2-11` 只有 `padding`）—— 卡片直接坐在页面底色上。
- `.card`（`:45-63`）：
  ```css
  border: 0;                                   /* 描边由 elevation 发丝线画，不占布局 */
  --dsw-elevation-stroke-color: var(--dsw-alias-border-l2);
  background: var(--dsw-specific-input-major);
  box-shadow: var(--dsw-elevation-soft);
  ```
- `--dsw-specific-input-major`：亮 = `neutral-bluish-00`（**也是白**）、
  暗 = `neutral-bluish-850`（`design-platform.css:269,387`）。
- `--dsw-elevation-soft`（`gradient-shadow-text.css:33,38-39`）：
  ```css
  var(--dsw-elevation-stroke),              /* 0 0 0 0.5px <stroke-color> */
  0 4px 16px 0 rgba(0,0,0,0.03),
  0 0 24px  0 rgba(0,0,0,0.03);
  ```
- `--dsw-alias-border-l2`：亮 `rgba(0,0,0,0.1)`、暗 `rgba(255,255,255,0.12)`
  （`design-platform.css:187,305`）。

**结论：亮色下 DSH 的卡片也是白的 —— "看得见"完全靠那层阴影。**
所以只改底色是改不出来的（这是本次调查最关键的一条）。

## Decision

1. `DshColorTokens` 加两个 token（明暗各一份，值与 DSH 逐字一致）：
   `composer`（`--dsw-specific-input-major`）、`borderL2`（`--dsw-alias-border-l2`）。
2. 输入栏外层底色 `c.sidebar` → **`c.bgBase`**（去掉灰带；与 DSH 的"根无背景"等价）。
3. 卡片底色 `c.layer1` → **`c.composer`**，并加三层 `boxShadow`：
   - `BoxShadow(color: c.borderL2, spreadRadius: 0.5)` ← 发丝环
   - `BoxShadow(color: 0x08000000, blurRadius: 16, offset: (0,4))`
   - `BoxShadow(color: 0x08000000, blurRadius: 24)`

   `rgba(0,0,0,0.03)` → alpha `0.03×255 ≈ 8` → `0x08`。

## Alternatives considered（否掉的）

- **只给卡片换个底色**（比如浅灰）：DSH 的亮色卡片就是白，靠阴影分层；
  自己发明一个灰会与 `bg-layer-*` 的语义打架，且深色下没有对应物。否。
- **用 `Border.all` 画描边**：DSH 明确 `border: 0`，描边走 elevation
  发丝线（"不占布局"）。Flutter 里用 `spreadRadius: 0.5` 的零模糊阴影
  等价，且不参与 layout。否（但两者视觉几乎一致，这里选更贴 DSH 的）。
- **照搬 `elevation-panel` / `elevation-prominent`**：输入栏在 DSH 用的是
  `soft` 这一档。否。

## Consequences

- 收益：输入栏读作"浮在会话上的一张卡"，底部不再是一条断开的灰栏；
  亮色下第一次真正有层次（此前白卡在白底上等于隐形）。
- 代价：`DshColorTokens` 多两个字段（6 处构造点跟着改）；
  输入栏外层不再用 `sidebar` 色（若将来想恢复灰带，改一行即可）。
- **真机像素证据（改后）**：`x=30` 竖向从页面白平滑落到
  `#FEFEFE → #FDFDFD → #FCFCFC → #FBFBFB → #FAFAFA → #F3F3F3 → #E6E6E6 → #DFDFDF`
  （y=2058..2124）—— 正是 `elevation-soft` 的两层模糊；原先那段
  `#F1F3F5` 灰带消失。
- 测试：`flutter test 841` 全绿（本次是纯视觉改动，原有布局判据未变；
  输入栏三条硬规则的判据仍在 `composer_layout_test.dart`）。
