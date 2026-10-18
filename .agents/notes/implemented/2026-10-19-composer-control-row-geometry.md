# Agent Note: 输入栏控制行的几何判据（"模型占那么大"的处置）

Status: implemented

## Problem

用户 2026-10-19 原话："我们的输入款就设计不是和很好，模型占那么大"。

同一天已做过一轮：模型 chip 从"裸名字"改成"`database` 图标 + 名字"
（照 rikkahub `ModelSelectorButton(onlyIcon = true)` 的图标优先思路；
图标取 DSH Web 触发器那个 `IconDataOutlineRegular`，
`ui-model-selection/src/client/ModelSelect.tsx:484`）。
但**那轮没有几何判据** —— "占多大"全凭感觉，下一轮改布局时没有东西会红。

## 调查（都不猜，逐条查了）

### 1. DSH Web 的触发器是四级结构

`ModelSelect.tsx:484-491`：

```tsx
<IconDataOutlineRegular className={css.triggerIcon} size={16} />
<span className={css.triggerLabel}>{…model.name…}</span>
{effortLabel !== undefined && <span className={css.triggerEffort}>{effortLabel}</span>}
{busy ? <StateDot …/> : <IconChevronDownOutlineRegular …/>}
```

`renderModelLabel` 的 fallback 是 `model.name`（`:442`）—— **全名，没有短格式**。
我们的 chip 与它逐项对应（图标 / 名字 / `· 推理等级` / chevron），
所以"占地方"不是我们加多了，而是**同一结构放在窄屏上**。

### 2. 实测占比（widget 测试量出来的，不是估的）

800px 宽的测试屏上：`＋` 38px(4.8%)、模型**文字** 233px(29.1%)、
权限 34px(4.3%)、发送 38px(4.8%)。加上 chip 的 padding/图标/推理等级/chevron，
整个模型 chip 约 **40%**。按 390px 真机折算约 156px —— 左组一半以上。

### 3. rikkahub 的做法是 `onlyIcon`

`app/src/main/java/me/rerere/rikkahub/ui/components/ai/ChatInput.kt:309-313` 的
`ModelSelectorButton(onlyIcon = true)`：**纯图标，0 文字**。
它省宽度，但代价是"当前是哪个模型"要点开才知道。

## Decision

**保持当前结构（与 DSH 四级同源），把几何判据钉住**，不改成 `onlyIcon`：

1. 模型 chip **不超过左组 62%**（原型 `#chipModel { max-width: 62% }` 的同一条）；
2. 权限 chip **恒宽 34**（硬规则 3 的后半句：长模型名不许把它挤走）；
3. 发送键在最右、不与左组重叠；
4. 长模型名（`deepseek-v4.1-flash-pro-preview-2026`）下 1/2/3 仍成立。

新增 `app/test/composer_layout_test.dart` 2 项。

**为什么不改成纯图标**：手机上没有 hover，"此刻用哪个模型"是高频信息
（用户换模型比换权限档勤）；纯图标要点开才知道，而"点开才发现选错了"
比"占 40% 宽"更影响使用。**这是有意偏离 rikkahub**，理由记在这里。

**为什么不动 62% 这个数**：改小会让名字更早被省略号截断 —— 用户反而更不知道
是哪个模型；改大则挤权限图标。62% 是原型定的，两条路都试过之后它仍是平衡点。

## Consequences

- 收益："模型占多大"从感觉变成判据；下一轮加"推理等级独立 chip"
  （rikkahub 的 `ReasoningButton(onlyIcon = true)`，`ChatInput.kt:342-348`）时，
  这两条会立刻告诉我们会挤成什么样。
- 代价：无（只加测试）。
- **未做**：rikkahub 的 `weight(1f) + horizontalScroll` 横滚钮组
  （`ChatInput.kt:302-306`）。现在控制行四个钮不换行，加第五个时才需要它。
