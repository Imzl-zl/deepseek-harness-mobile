# 用量页

跨会话用量汇总的一页（`app/lib/ui/usage_page.dart`）。数据来自连接器自己的
`usage.summary`（契约 §5.7）—— **DSH 没有跨会话用量接口**，`tokenUsage` 投影是单会话的
（`llm/token-meter/src/usage-projection.ts:56-63` 的 state 是 `{totals, last}`）。

## 1. 一页放什么（累计 → 近期 → 明细）

| 块 | 内容 | 判据 |
|---|---|---|
| 总量卡 | 全部会话的 token 总量 + 会话数 + **构成条**（四个桶按比例）+ 缓存命中率 | `grandTotalTokens` / `sessions` / `totals` |
| 四格卡片 | 未缓存输入 / 输出 / 缓存读 / 缓存写，**每格带自己的占比**（与构成条同色圆点） | `totals.*` |
| 近期活动 | 今天 / 近 N 天的 token 与轮次、与前 N 天的对比、日均与平均每轮；窗口 7 / 30 / 90（**切窗口 = 重新请求**）；**分批统计时显示 `已扫/总数`** | `byDay` + `daysProgress`（`usage.summary {days}`） |
| 热力图 | 一格一天，深浅 = 那天用掉多少 token；点一格读出当天（日期 · 轮次 · token）；左星期、上月份、下图例 | 同上 |
| 项目段 | 项目名 · 用量 · 会话数 · **占全库的比例条**，头可点折叠（默认展开），展开后是该项目的会话行（每行带项目内占比） | `byProject` + `bySession` |
| 兜底 | 没有 `byProject`（老连接器）⇒ 退回"按会话"扁平榜 | — |
| 真没有用量 | 总量 0 且没有任何有数据的会话 ⇒ 一句"还没有用量数据"，**不摆 0 卡** | `grandTotalTokens == 0 && bySession.isEmpty` |

数字格式**只有一个来源**：`model/session_stats.dart` 的 `formatTokenCount` /
`formatCacheHitPercent` —— 与单会话统计条上的那个数字必须长得一样。

## 2. 数据面与口径

`usage.summary` 回的字段：`{sessions, grandTotalTokens, totals, byProject, bySession, byDay?}`。

- **总量 / 分项 / 项目 / 会话**来自 `session.list` 行自带的 `tokenUsage` 投影提示（一次往返）。
- **按天活动**要读每个会话的 `trajectory`（日志），所以是**第二次请求**：带 `days` 才返回，
  只读窗口内更新过的会话，按投影水位缓存。页面先出总量，活动后补。
- **活动分批扫**：电脑侧每次只新扫 4 个会话，应答带 `daysProgress:{scanned,total}`；
  `scanned < total` 时手机 350ms 后自己要下一批（`AppModel.refreshUsageDays` 的补批，
  不闪"正在读取"），界面写"正在统计活动 N/M 个会话"。扫完才是完整的一天一格。
- 页面要的天数是 `2 × 窗口`：多一点给"前一段"的对比，不增加会话数。

**聚合规则写在契约 §5.7 的 `usage.summary` 行**（子智能体不计入 / 全零不进榜 /
`cwd` 空的单独一档 / `byDay` 的轮次与 token 都是真值 / 日期取电脑侧本地时区）。
这里不复制那份清单，避免两处漂。

## 3. 形态（本仓自己的设计）

**DSH 桌面没有用量页**（`packages/client` 下没有 `ui-usage`，只有账户页一个"查询用量"链接），
所以对齐对象不是 DSH，而是成熟实现的形态：卡片网格 + 按天热力图
（rikkahub `ui/pages/stats/StatsPage.kt` 的 `StatsGrid` / `ChatHeatmap`）。

口径要点：

- 热力图**窗口只有 7 / 30 / 90 天**：一年窗口要把几乎全部会话的日志读一遍，代价与收益
  不成比例；90 天覆盖"最近在不在干活"。
- **格子 10dp、缝 3dp**，所以网格**横向可滚**（星期列固定不动、默认停在最右）；
  4dp 的装饰格点不中，那是"只能看个样子"的根源。
- **可以点**：点一格 → 标题右侧读出 `10月3日 · 3 轮 · 12.4K tok`；选中的格子加描边。
- 色阶是**纯函数** `heatAlphaAt(tokens, scale)`：`0` = 底色（不是透明）；非零按窗口内
  自己的四分位分五档 —— 不发明"多少 token 算多"的绝对阈值，图例右侧标出中位值。

## 4. 已知边界

- **老连接器**（总量应答里带 `byDay`、不认 `days`）：页面照样画 —— 活动区块用总量里那份
  `byDay` 兜底；没有 `totals` 时四格与构成条整块不出现（不摆四个 0）。
- **热力图的覆盖范围** = 各会话 `trajectory` 保留的最近 **200 轮**
  （`connector/src/dsh/trajectory.ts:98` 的 `MAX_TURNS`）。更早的活动不在里面 —— 这是上界，不是漏算。
- **分批期间的数字会继续长**：`scanned < total` 时"近 N 天"只是已扫会话的和，
  界面必须同时显示 `已扫/总数` —— 半份账不能装成完整结果。
- **折叠态不持久**：离开页面即回到默认展开（不为一个"看着方便"的开关开存储）。
- **轮次只在活动区块出现**：全库轮次没有可靠来源（`trajectory` 只保留每会话最近 200 轮），
  摆一个"看起来是总量"的轮次就是编。
- **首屏在途时显示"正在读取…"**，不是"还没有用量数据" —— 后者会被读成"电脑上真的没有"。

## 5. 接线

`UsagePageHost` 是唯一入口：`initState` 拉总量（`refreshUsageSummary`）与默认 30 天活动
（`refreshUsageDays(30)`），并用 `ListenableBuilder` 听 `AppModel`。窗口胶囊的回调也由它
转给 `AppModel.refreshUsageDays`。**页面本身无状态**（拉取归 `AppModel`，页面只显示）。

## 6. 验证

`cd app && flutter test test/usage_page_test.dart` —— 22 项：三级结构、项目头折叠、
四格 / 构成条尺寸与可见性 / 缓存命中 / 占比、活动两行读数与对比文案、分批补拉与进度、
热力图"有数据才出现"（含对照组）、`fromWire` 两种形状、`heatAlphaAt` 阈值与单调性、
窗口 7/30/90 与"切窗口是一次回调"、点会话行的回调、拉不到时如实说原因、
`UsagePageHost` 拉到后自己重画且**两次请求**。
