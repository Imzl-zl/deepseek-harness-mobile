# Agent Note: 把文档里过期的事实改回当下事实（输入区 / 抽屉 / 底栏）

Status: implemented

## Problem

`docs/design-and-tech-plan.md` 与 `docs/settings-porting-notes.md` 里有若干处
**与落地代码矛盾**的陈述。按项目纪律（`AGENTS.md`「视觉与文案以
`docs/design-and-tech-plan.md` 为基线;与文档冲突时先改文档再改代码」），
矛盾本身就是缺陷 —— 后来人会照文档改代码，把已经改对的东西改回去。

发现的矛盾（逐条核对过代码）：

| 位置 | 文档说 | 代码是 |
|---|---|---|
| plan 输入区示意图 | `＋ 模型·等级 权限 ↑` | `＋ 权限 模型 等级 ↑` |
| plan 硬规则 3 | 左组含「发送模式图标」 | 那个图标已移除，偏好搬进设置页 |
| plan 硬规则 3 | 模型 chip 上限「62%」 | 是**左组剩余空间**的 62%（`LayoutBuilder`） |
| plan 抽屉宽度 | 横屏/≥700 用右抽屉 `min(62%,560)`，竖屏**全屏** | **永远是抽屉** `min(300dp, 屏宽×0.86)` + 头部全屏钮 |
| plan 左抽屉底栏 | 「设置/文件/终端」 | 文件 / 归档 / **用量** / 设置（无终端页） |
| plan 拖出区 | `drawerEdgeDragWidth: 32` | `min(28% 屏宽, 64dp)` |
| settings 行 50 | 发送模式「放在输入区控制行（第 4 个 34px 图标）」 | 在设置页「通用」组（**与 DSH 一致**，偏离已消失） |

另外删掉一句计划阶段的残留（「第一版:会话+抽屉+设置;文件/终端按 bridge
能力再上」）—— 它既过期，又属于 `docs/AGENTS.md` 第 1 条禁止的变迁叙述。

## Decision

1. 全部改成**当下事实**的写法，不写「以前是 / 现在改成了」。
2. **发送模式的细节下沉到 `settings-porting-notes.md` 那一行**（它本来就有
   一行讲这一项），`plan` 里只留一句 + 指向。
3. 核对并保留了两个 DSH 行号引用（`ui-layout/src/client/columns.ts:25` 的
   `RIGHTBAR_MIN = 300`、`ui-sidebar-right/.../SidebarRight.tsx:263` 的
   `PanelChrome`）—— 都在原位，未漂移。

## 字数预算的处理（这一步是本笔记存在的主要理由）

`docs/AGENTS.md`：`design-and-tech-plan.md` ≤3,000 词，**当前约 2,970，贴近上限**。
我的修改净增了内容。按第 4 条的处置顺序，**先下沉、再精简**，不许先删约束：

1. 发送模式的整段 → 下沉到 `settings-porting-notes.md`（合法归宿：它是一项设置）；
2. 视觉分层那段压成一句；
3. 删掉「第一版」那句残留（既过期又是变迁叙述 —— 删它不损失任何约束）。

结果净增约 20 词（≈2,990/3,000）。**同时把 `docs/AGENTS.md` 里自报的
「约 2,970」改成「约 2,990，已到上限」** —— 那个数字是文档自己的哨兵，
不跟着改就失效了。

## Alternatives considered（否掉的）

- **申请提额**：第 4 条把它排在最后，而这次的内容确实可以下沉，没到必须提额的
  地步。否。
- **把矛盾留着、只在笔记里写"代码已经不一样了"**：矛盾还在文档里，
  后来人照样会照它改代码。否。
- **新建 `docs/subsystems/composer.md` 承载视觉分层**：为一段话开一个新文件，
  还要动 `docs/AGENTS.md` 的文档表格，成本高于收益。否。

## Consequences

- 收益：`plan` 与 `settings-porting-notes` 重新可作为基线；字数回到预算内。
- 代价：`plan` 里关于输入区的细节变少了（细节在 settings 文档与决策笔记里）。
- 验证：改的是文档，代码门禁不受影响；已重跑 `flutter test 867` / `analyze 0` /
  `format 0` / `boundary 297` 确认工作树仍然绿。
