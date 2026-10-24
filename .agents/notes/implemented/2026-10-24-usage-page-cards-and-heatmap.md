# Agent Note: 用量页改成"卡片 + 热力图"，`usage.summary` 补 `totals` 与 `byDay`

Status: implemented

## Problem

用量页原来是「总量卡 → 每个项目一个头 → 该项目的会话行」，全**平铺**：

- **没有时间维度** —— 看不出"这几天在不在干活"；
- **没有构成** —— 只有一个总数，输入 / 输出 / 缓存各占多少看不见；
- **不可折叠** —— 项目一多就一路往下滚（用户 2026-10-24 原话"现在的不好看也体验不好"）。

对齐对象不是 DSH：**桌面没有用量页**（`packages/client` 下六十多个包里没有 `ui-usage`，
只有账户页一个"查询用量"的链接）。所以这是本仓自己的面，形态要有据可依 ——
依据取的是成熟实现：rikkahub 的 `ui/pages/stats/StatsPage.kt`（356 行）
= **卡片网格**（`StatsGrid` / `StatCard` / `formatTokens`）+ **按天热力图**
（`ChatHeatmap`，数据是 `Map<LocalDate, Int>`，`StatsVM.kt:20-29`）。

数据侧原本也不够：`usage.summary` 只有 `{sessions, grandTotalTokens, byProject, bySession}`
—— 总量是"全部数值字段求和"，**分项被求和吃掉了**；也没有按天。

## Decision

### 电脑侧（`usage.summary` 多两个字段，都是既有真值的转发）

- `totals: {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}`
  —— 键名**原样用 DSH 的**（`llm/token-meter/src/usage-projection.ts:16-21` 的 `zeroBuckets`），
  连接器不做"提示词/补全"这类翻译（词属于界面）。
- `byDay: [{date, turns}]` —— **只数轮次**，日期取**电脑侧本地时区**。
  数据来自同一包投影里的 `trajectory`（本仓自带那个投影，每轮有 `startTime`），
  所以**没有额外往返**：`projections.of()` 本来就把整包 `values` 拿回来了。
- 契约 §5.7 的 `usage.summary` 行同步（返回形状 + 聚合规则⑤）。

### 手机侧

- **四格小卡片**：输入（未命中缓存）/ 输出 / 缓存读·写 / 轮次。
- **52 周热力图**：一格一天。**颜色 = 那天的 token**、**点一格读出当天**（日期 · 轮次 · token），
  左星期 / 上月份 / 下图例；格 10dp ⇒ 约 673dp，网格横向可滚（星期列固定）。
  色阶纯函数 `heatAlphaAt(tokens, scale)`，按这一年自己的四分位分档。

## 2026-10-24 追加：热力图从"看个样子"改成"能读出数字"

用户原话：「有矩阵图但是不能看是哪一天用多少就是一个样子啊」。根因两条，都是我的问题：

1. **4dp 的格子点不中** —— 那不是交互，是装饰。改成 10dp + 横向滚动。
2. **只能画轮次**，因为当时判定"投影里没有每轮的 token"。**这条判定是错的**：
   `assistant/message` 自带 `data.usage`（`usage-projection.ts:83`），而 `trajectory` 投影
   本来就在折这个事件（助手段的终点）—— 顺手累加就有了"每轮多少"，
   于是 `byDay` 能给**真** token（`connector/src/dsh/trajectory.ts` 的 `TrajectoryTurn.tokens`）。
   契约 §5.7 的规则⑤ 随之改写（从"只数轮次"变成"轮次与 token 都是真值"）。

判据：connector **621**（+1：每轮 token 累加；`byDay` 断言从 `{date,turns}` 变 `{date,turns,tokens}`）、
flutter **1174**（+1：点一格读出当天；色阶改成按分位的 `heatAlphaAt`）。
- **项目段可折叠**：点头收起/展开，**默认展开**（折叠是省屏手段，不该默认藏信息）。
- **老连接器不报那两个键 ⇒ 两块都不出现**：不摆四个 0、也不画一张空热力图
  （`UsageSummary.totals` 是 `null`、`byDay` 是空表，界面按"不知道"处理）。

## Alternatives considered

1. ~~**26 周**~~ **采用 52 周**（与 rikkahub 同口径，2026-10-24 改回）。当初按"格子会挤到 4–5px"
   缩到 26 周，**算错了**：390dp 上可用 330dp，52 列 × 4dp + 51 条缝 × 2dp = 310dp，还留 20dp 余量；
   320dp 小屏退到 3dp 格仍在界内。密度本就是 GitHub 移动端那一档（读数靠深浅，不靠点）。
2. **按天摊 token 上热力图** —— 最强理由：用户真正关心的是"花了多少"，不是"跑了几轮"。
   被否：`tokenUsage` 投影只有**会话累计**，没有"每一轮多少"；按天摊就是把总量平均到轮次数上，
   那是编出来的数字（本项目最不能碰的一类）。所以热力图如实只数轮次，卡片上再给 token 构成。
3. **用 `session.list` 的 `updatedAt` 当"那天有活动"** —— 最强理由：零新增字段，现成就有。
   被否：一个会话只有一个时间戳，画出来是"最近改过的会话分布"，不是活动量；
   而且它会让"同一个会话跑了一周"看起来像"只活跃了一天"。
4. **默认收起** —— 最强理由：一屏看完全部项目名与总量，最省滚动。
   被否：默认藏信息；展开是默认行为，折叠是用户主动选的。
5. **读会话日志算完整历史** —— 最强理由：不受投影上限约束，热力图覆盖全部历史。
   被否：N 个会话 × 全量日志解析，代价与收益不成比例；`MAX_TURNS = 200` 的上界如实写进契约。

## Consequences

- **收益**：一页同时回答"总共多少 / 花在哪 / 哪些天在干活"；三块都来自既有真值，没有新的记账。
- **代价（如实记）**：热力图的覆盖范围 = 各会话 `trajectory` 保留的**最近 200 轮**
  （`connector/src/dsh/trajectory.ts:98`）。老会话的早期活动**不在里面** ——
  契约 §5.7 的规则⑤写明这是上界，不是漏算。
- **代价**：四格卡片与热力图**依赖新连接器**；老连接器只有总量卡（界面不留空壳）。
- **代价**：折叠态**不持久**（离开页面即回到默认展开）。没有落盘 —— 一个"看着方便"的开关
  不值得开一份存储（与"未读收口不落盘"同一条理由）。
- 有意偏离照旧记在 `docs/subsystems/usage-page.md`：DSH 没有这一页，形态是本仓设计的。

## 判据

- connector **617 → 620**：`totals` 四键原样过线并与老字段对得上（四个分项之和 = `grandTotalTokens`）；
  `byDay` 跨会话按天合并、**日期升序**（用"后一个会话的轮更早"构造，防止按会话顺序凑巧对）；
  "没有 `trajectory` ⇒ `byDay` 空"（不是"今天 0 轮"）。
- flutter **1160 → 1164**：`四个分项 + 热力图：有数据才出现`（含轮次 = `byDay` 之和）、
  `项目头可折叠：点一下收起，再点展开`、`fromWire` 的两种形状（有/无 `totals`、`byDay`）、
  `heatAlphaOf` 的阈值与单调性；第一条用例补**对照组**（老 fixture 下两块都不出现）。
- **变异校验**：把项目头的 `onTap` 改成空操作 ⇒ **恰好**"项目头可折叠"那条红（做完即还原）。
- boundary **363** 持平、`dart analyze --fatal-infos` 0、`dart format` 0、`tsc --noEmit` 0、`pnpm build` 过。

## 代码入口回指

`connector/src/handlers.ts` 的 `bucketsOf` / `turnsByDayOf` 与 `usage.summary`；
`app/lib/model/usage_summary.dart` 的 `UsageTotals` / `UsageDay` / `fromWire`；
`app/lib/ui/usage_page.dart` 的 `_BreakdownGrid` / `_HeatmapCard` / `heatAlphaOf` / `_ProjectSection`。
