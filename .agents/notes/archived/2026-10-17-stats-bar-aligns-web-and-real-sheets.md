# Agent Note: 统计条逐字对齐 Web（`{total} tok · 缓存命中 {percent}%`）+  Wrap 布局 + 三个 sheet 接真投影

Status: archived

Superseded by: `.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`

取代范围：**只有决定 3 里的"`Row` → `Wrap`（放不下换行）"这一处** ——
新篇改成**单行 + 横向滚动**（用户 2026-10-17 定案："就一行，超出得可以滚动查看"）。
本篇**其余结论仍然有效**：文案与合计逐字照 Web、`formatCacheHitPercent` 的移植
（部分命中绝不显示成 100）、上下文 chip 的 14px 小环、三个 sheet 全部接真投影、
以及 `简洁` 档的口径。**下面的结论原文不改** —— 它记录了当时为什么那么想，
以及备选里"把三项塞进横滚容器"当初为什么被否（理由是"读数被藏到屏幕外"；
新篇区分了**被裁掉**与**滑得到**，并把这个取舍交回用户定）。
另：本篇决定 1 写的 `{turns} 轮 {steps} 步` 是对的，但代码当时落成了
`第 {turns} 轮 · {steps} 步` —— 新篇一并改正。

## Problem

真机反馈（2026-10-17）："输入框最下面的状态，缓存命中文案没对齐web，
上下文百分比不显示（这些字可以再小点，因为状态的数字会变化，你现在都占满了，
数字变四位数那怎么办？）"。

三个独立问题：

1. **文案分叉**：手机显示 `302K · 缓存 96%`，Web 是 `302K tok · 缓存命中 96%`
   （`locale.ts:78` 的 `stats.cacheHit` + `message.turnUsage.count` 的 `{count} tok`）。
   合计也不同：手机用 `totalInput`，Web 用 `billedInput + output`
   （`StatsPills.tsx:295`）。
2. **上下文百分比被裁掉**：统计条是 `Row`，三项总宽超屏时**把末项整块裁掉**——
   release 里没有溢出条纹，只是看不见。真机上"百分比不显示"正是这么来的。
3. **三个 sheet 全是写死的数**（`12.4 / 3.8 / 420 / 516 / 1 · 3` 与
   `7200/10100/2600/1000000`）——与电脑侧毫无关系，而用户无法分辨哪个是真的。
   另有两个格式化分叉：`formatTokenCount` 在 `[10K,100K)` 取整（Web 保留一位
   小数），tps 一律 `.round()`（Web ≥10 才取整）。

## Decision

1. **文案与合计逐字照 Web**：`{total} tok · 缓存命中 {percent}%`、
   `{turns} 轮 {steps} 步 · {tps} tok/s`；合计 = `billedInput + output`。
2. **`formatCacheHitPercent` 逐字移植** Web 的 `token-format.ts:67-97`：
   整数四舍五入（.5 向上），**部分命中绝不显示成 100**（补小数位直到诚实）。
   向量表直接照抄 Web 自己的测试（`chat-stats.client.spec.tsx:215-236`，
   含 `MAX_SAFE_INTEGER-1` 那条）。
3. **`Row` → `Wrap`**（放不下换行，没有"被藏起来的读数"）+ 字号 12→11
   + chip 文本 `ellipsis` 兜底（系统大字缩放时省略号比溢出裁切好）。
4. **上下文 chip 补上小环**（照 `ContextMeter.tsx:119-129` 的 14px 环）。
5. **三个 sheet 全部接真投影**：`sessionStats`（含新解析的 `ttftMs`/`ttftSteps`）、
   `tokenUsage`、`contextPressure` + `contextBreakdown`（新解析）。
   **哪项没有数据就不摆那一行**（Web 的 `stats.llmMs > 0 && …` 同一个门），
   空态说"电脑侧还没有报告"，不摆零值。
6. **`简洁` 档**（新偏好，见设置页笔记）：统计 pill 只留速率与缓存命中
   （Web 的 `usePerformanceUsage === 'compact'`）。

## Alternatives considered（否掉的）

- **把三项塞进横滚容器**（原型旧做法）：读数被藏到屏幕外，正是用户投诉的形态。
- **砍掉某一项**（如百分比）：丢读数。
- **自己写一个"不会溢出"的固定宽度**：数字宽度随数据变，任何固定值都会在
  四位数字前失效。

## Consequences

- 收益：与 Web 同一个字符串；四位数不变形；sheet 从假数据变真数据。
- 代价：`session_stats.dart` 多了四个格式化函数与两个新投影字段的解析；
  统计 sheet 的行数随数据变（测试从"找五个写死的值"改成"找投影算出的值"）。
- 新测试用 Web spec 的同一批向量（外部规格，不是自己想的数）。
