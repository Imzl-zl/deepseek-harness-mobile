# App P1（官方移动端对齐）实施清单与现状（0.2.10 计划）

- 日期：2026-11-05
- 来源：`2026-11-05-absorb-official-mobile-022.md` 的 P1 五项
- 状态：proposed（本版先落 P0；P1 按下面顺序逐项实现）
- 分支：`dsh-mobile/app-0.2.9`（在其上继续，完成一项升一次 `0.2.10+5` 等）

## 现状核查（基于 `review-fixes-20261104` 分支）

| # | 官方能力 | 现状 | 缺口 / 改法 |
|---|---|---|---|
| 1 | 后台任务完成通知带小输出、去重 | 通知按内容派生 id 去重（`noticeIdOf`）；`NoticeKind` 只有 approval / question / completed；**无 job 完成通知** | 在 job 状态流处新增 `NoticeKind.job`：仅当 App 不在前台且该会话非当前时发；body 取 job 输出尾部（截断 ~200 字），id 用 `job:<jobId>`；job 已有去重/结算事件可直接复用 |
| 2 | 工作步骤收起后保留助手文字；可切"仅最终回答" | 助手正文**始终显示**，收起只隐藏思考（`showReasoning=false`，与 DSH `compactAnswer` 一致） | 已有"保留正文"；新增偏好 `host.<hostId>.finalOnly`（默认关）：开时轮组只留最后一条 assistant 正文、隐藏中间过程卡 |
| 3 | 已回答问题批次以气泡回看 | 待处理提问在 `takeover.dart` 接管卡；回答后条目从待处理消失，聊天流无回看条目 | 在 `projection.dart` 把 `ask_user_question` 的 tool/call + 已解开的回答折成只读 `QuestionItem`（`answered: true`），`chat_turns.dart` 渲染成卡片；不改协议 |
| 4 | Trajectory 子调用折叠 + 原始 JSON 查看 | 轨迹页按 `steps` 平铺渲染，未见子调用层级 | 先核实 `steptrace` 投影是否带 `parentCallId`/嵌套；有则加可折叠子行；"原始 JSON"用该 step 已有 payload 字段渲染（只读抽屉） |
| 5 | 文件预览：常驻目录树 + 定位 + 行号高亮 | 文件页 = 列表 + 预览；无树、无行号跳转高亮 | 文件页拆两栏（窄屏抽屉）：左目录树（按路径前缀折叠）、右预览；预览行号锚点 + `Scrollable.ensureVisible` 淡出高亮 |

## 实施顺序与验收

1. **通知（#1）**：`flutter analyze`；单测：假 job 完成 → 期望 notices 含 `job:<id>` 且 body 有尾部；前台/当前会话不提醒。
2. **仅最终回答（#2）**：偏好读写 + 渲染切换；单测投影过滤。
3. **Trajectory（#4）**：先读投影类型再决定（没有层级就只做"原始 JSON"）。
4. **问答回看（#3）**：投影 + 渲染；单测：已答问题出现一次、断开重连后仍在。
5. **文件树（#5）**：UI 改造，需真机看窄屏。

## 构建与发布

- 每完成一批：`flutter analyze --no-pub` → 版本号 +1 → 推分支 → 按
  `_scratch/dsh-app-0.2.9-build/` 同款流程打包给那台电脑构建（同一 debug keystore，
  可覆盖安装）。
- 自用版：可含我们的说明；若要给作者 PR：剥离 `dsh.songzuo.online`、令牌、内部笔记后再推。
