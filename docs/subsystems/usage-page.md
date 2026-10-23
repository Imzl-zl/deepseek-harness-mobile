# 用量页

跨会话用量汇总的一页（`app/lib/ui/usage_page.dart`）。数据来自连接器自己的
`usage.summary`（契约 §5.7）—— **DSH 没有跨会话用量接口**，`tokenUsage` 投影是单会话的
（`llm/token-meter/src/usage-projection.ts:56-63` 的 state 是 `{totals, last}`）。

## 1. 一页放什么（从总到分）

| 块 | 内容 | 判据 |
|---|---|---|
| 总量卡 | 全部会话的 token 总量 + 会话数 | `grandTotalTokens` / `sessions` |
| 四格卡片 | 输入（未命中缓存）/ 输出 / 缓存读·写 / 轮次 | `totals.*` 与 `byDay` 的轮次和 |
| 热力图 | 最近 **26 周**，一格一天，深浅 = 那天开了几轮 | `byDay` |
| 项目段 | 项目名 · 用量 · 会话数，**头可点折叠**（默认展开），展开后是该项目的会话行 | `byProject` + `bySession` |
| 兜底 | 没有 `byProject`（老连接器）⇒ 退回"按会话"扁平榜 | — |

数字格式**只有一个来源**：`model/session_stats.dart` 的 `formatTokenCount`
—— 与单会话统计条上的那个数字必须长得一样。

## 2. 数据面与口径

`usage.summary` 回的字段：`{sessions, grandTotalTokens, totals, byDay, byProject, bySession}`。

**聚合规则写在契约 §5.7 的 `usage.summary` 行**（子智能体不计入 / 全零不进榜 /
`cwd` 空的单独一档 / `byDay` 只数轮次不摊 token / 日期取电脑侧本地时区）。
这里不复制那份清单，避免两处漂。

## 3. 形态（本仓自己的设计）

**DSH 桌面没有用量页**（`packages/client` 下没有 `ui-usage`，只有账户页一个"查询用量"链接），
所以对齐对象不是 DSH，而是成熟实现的形态：卡片网格 + 按天热力图
（rikkahub `ui/pages/stats/StatsPage.kt` 的 `StatsGrid` / `ChatHeatmap`）。

两处**有意偏离**该参照：

- 热力图取 **26 周**而不是 52 周：390dp 上 52 周的格子只剩 4–5px，深浅读不出、也点不到；
- 热力图的色阶是**纯函数** `heatAlphaOf(turns)`（0 轮 = 底色，不是透明）—— 有判据、可单测。

## 4. 已知边界

- **老连接器**（不报 `totals` / `byDay`）：四格卡片与热力图**整块不出现**
  （`UsageSummary.totals == null`、`byDay` 空）—— 不摆四个 0、也不画空热力图。
- **热力图的覆盖范围** = 各会话 `trajectory` 保留的最近 **200 轮**
  （`connector/src/dsh/trajectory.ts:98` 的 `MAX_TURNS`）。更早的活动不在里面 —— 这是上界，不是漏算。
- **折叠态不持久**：离开页面即回到默认展开（不为一个"看着方便"的开关开存储）。
- **热力图只数轮次**：投影里没有"每一轮用了多少 token"，按天摊 token 就是编。

## 5. 接线

`UsagePageHost` 是唯一入口：`initState` 拉一次 `refreshUsageSummary()`，并用
`ListenableBuilder` 听 `AppModel`。**页面本身无状态**（拉取归 `AppModel`，页面只显示）——
直接把"拉之前的快照"塞进 `UsagePage` 会让它永远停在空态（2026-10-21 真机抓到的那条）。

## 6. 验证

`cd app && flutter test test/usage_page_test.dart` —— 11 项：三级结构、项目头折叠、
四格卡片与热力图"有数据才出现"（含对照组）、`fromWire` 两种形状、`heatAlphaOf` 阈值与单调性、
点会话行的回调、拉不到时如实说原因、`UsagePageHost` 拉到后自己重画。
