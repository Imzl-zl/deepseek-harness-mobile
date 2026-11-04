# 目标条（输入区 dock · 目标）

输入卡片上方、排队条**之上**的一条 dock：DSH 让长任务有一个跨轮次的目标
（`/goal <objective>` 建，`/goal pause|resume|clear|edit <objective>` 改），
这条 dock 就是那个目标的唯一可见处。**目标不是聊天消息**，所以它不在对话流里。

结构与文案照 `packages/client/ui-goal/src/client/GoalBar.tsx` 与
`GoalBar.module.css` 的 `.dock` / `.bar`。

## 1. 结构

| 部位 | 规格 | 出处 |
|---|---|---|
| 条高 | **36**（`minHeight`，见 §6） | `GoalBar.module.css:19-35` |
| 圆角 | `DshRadius.md`（12） | `:33` |
| 底色 | **菜单底** `c.menu`（`--dsw-specific-menu`） | `:37-46` |
| 浮起 | `elevation-panel`：`0 0 0 .5px border-l1` + `0 3px 8px rgba(0,0,0,.03)` + `0 0 16px rgba(0,0,0,.02)` | `gradient-shadow-text.css` 的 `--dsw-elevation-panel` |
| 内边距 | `12 / 4 / 5 / 4` | `GoalBar.module.css:30` |
| 一行四段 | 图标 14 → 阶段标签 13/24·500 → 正文 13/20（**一行省略**）→ 动作 28×28 | `GoalBar.tsx:132-171` |
| 图标 | `DshIcon('goal')`，`labelTertiary` | `GoalBar.module.css:48-52` |
| 正文色 | `c.labelPrimaryDimmed`（`--dsw-alias-label-primary-dimmed`） | `:64-73` |

实现：`app/lib/ui/goal_bar.dart`（`GoalBar`），挂在 `app/lib/ui/chat_page.dart`
的底部 dock 栈里 —— 顺序是接管卡 → **目标条** → 排队条 → 输入栏 → 统计条。

**子会话里不画**：那条通道没有命令面（`app/lib/model/command.dart` 的文件头：
子会话唯一的写入口是 `subagent.prompt`），四个动作发出去必然失败。
判据只有 `chat_page.dart` 的 `_goalBarVisible` 一处（它同时喂底部预算）。

## 2. 数据：`goal` 投影

键在 `session.projections` 的扁平 `values` 里，wire schema 逐字照
`packages/goal/goal/src/index.ts:61-77`：

```text
null
| { goal: { id, revision, objective,
           phase: 'active' | 'paused' | 'blocked' | 'complete',
           blockedReason?: { code, message }, maxGoalRounds },
    roundsStarted, createdAt, updatedAt }
```

- 解码：`app/lib/model/goal.dart` 的 `parseGoalView`；App 侧取值 `AppModel.goal`。
- **`null` 是"没有目标"**，与"这一包没有这个键"（老连接器 / 没装目标插件）在界面上
  同一表现：整条不画。DSH 同一条（`GoalBar.tsx:86`）。
- **形状不对 = 没有**：必填字段缺失 / 类型不对 / 阶段不在四值里 ⇒ 整个解析回 `null`，
  与其余 14 个投影键同一条纪律（不猜一个半懂的目标 —— 阶段决定画哪几个动作）。
- `blockedReason` 是**可选**字段（`goal/src/index.ts:69`）：它不是 `{code, message}`
  两个非空字符串时当"没给原因"，条子照画「受阻的目标」，只是没有 `title`。
- **没有 `activation`**：`armed` / `disarmed` 是**进程内**状态
  （`packages/goal/goal/src/types.ts:66`），要 `goals.get` 的 Remote 读或
  `goal/activation-changed` 事件，手机两条都没有。所以 `active` 一律当已激活：
  暂停钮在 `active` 时出现、`phase.active.disarmed`（"已暂停的目标"）这一档不显示。

## 3. 阶段与动作

| `phase` | 标签（`ui-goal/src/client/locales.ts:5-8`） | 动作 |
|---|---|---|
| `active` | 进行中的目标 | 暂停 / 编辑 / 清除 |
| `paused` | 已暂停的目标 | 恢复 / 编辑 / 清除 |
| `blocked` | 受阻的目标 | 恢复 / 编辑 / 清除（整条 `title` = `blockedReason.message`） |
| `complete` | **不画条** | — |
| `null` / 键缺席 / 形状不对 | **不画条** | — |

暂停与恢复**互斥**，所以最多三个动作钮（`GoalBar.tsx:140-153`）。
编辑是**行内输入框**（同一格里换成 `TextField` + 保存 / 取消），不弹 sheet：
保存发 `/goal edit <objective>`，空草稿不发（保存钮置灰）。
清除成功后**立刻不画**（`_clearedGoalId` 闩，`GoalBar.tsx:47,86`）——
投影要等 `goal/change` 那一趟往返，中间那段条子还挂着，用户会以为没清掉而再点一次。

## 4. 动作走斜杠命令

DSH 有 `goals` 的 Remote（`pause` / `resume` / `clear` / `edit`），手机这条通道
没有它（`connector/src/protocol/methods.ts` 的方法面里没有 `goal.*`）。四个动作一律：

| 动作 | 命令行 | 宿主解析 |
|---|---|---|
| 暂停 | `/goal pause` | `command-goal/src/index.ts:40,165-167` |
| 恢复 | `/goal resume` | `:41,168-170` |
| 清除 | `/goal clear` | `:39,171-174` |
| 编辑 | `/goal edit <objective>` | `:43,154-164` |

都走 `AppModel.executeCommand` → `command.execute`（白名单
`connector/src/handlers.ts:88` 的 `MOBILE_COMMANDS` 已放行 `/goal`）。

**结论按 `CommandOutcome` 的既有约定呈现**（与 `chat_page.dart` 的
`_switchPermission` 同一个三段式）：没有结论 ⇒ 浮层说「目标操作失败：<原因>」；
`matched:false` ⇒「这台电脑上没有 /goal 命令」；`kind:'error'` ⇒ **DSH 原文照显**。
**成功不弹**：条子自己会变（§5），而 `DshToast` 的第一条规则就是"结果看得见的不弹"。

代价（如实记）：命令会在对话流里落一张 `/goal` 命令卡（标题 `/goal`、摘要 `Goal paused`
这种，`CommandCard` 读 `command/run` + `command/done`）；它属于执行那一刻的轮次，
默认收在轮组的**折叠过程**里（展开那一轮才看得见）。这是"不开新方法"这条决定的
直接后果，不是缺陷；要消掉它就得给连接器加 `goal.*` 四个方法。

## 5. 刷新：`goal/change` 到达就重读投影

`goal` 投影由两种会话事件推进（`packages/goal/goal/src/index.ts:142-155` 的 fold）：
`goal/change` 改目标的身份 / 阶段 / 正文；`source.kind === 'goal'` 的用户消息只推进
`roundsStarted`（`packages/goal/goal/src/fold.ts:326-330`）—— 而条子不画轮次。
所以重读只认 `goal/change`。

而投影包在手机上的重读时机是封闭登记表里的一列
（`app/lib/data/host_state.dart` 的 `session.projections` 行）：`notification` /
`openSession` / `connectLanding` / `appResume` / `viewFocus` —— **都不覆盖"电脑上改了目标"**。

所以收帧回调里补一处：`AppModel._onDelta` 见到 `goal/change` 就记一笔，
循环结束后 `_refreshProjectionsOnce(sid)`（与 `turn/end` 同一个合并闸：
在飞 + 攒一次，同批两条信号只发一次请求）。它同时覆盖：

- 手机自己点暂停 / 恢复 / 编辑 / 清除之后；
- **桌面（Web）上改了目标，手机跟上** —— 两边读的是同一个投影。

`goal/change` **不落条目**：它是状态事件、没有可渲染的正文（与 `agent/inbox/spliced`
同一条处理），落成 `OtherItem` 只会往本地库里塞一行永远不显示的东西。

## 6. 与 DSH 的有意偏离

1. **动作失败用浮层提示**（`DshToast`），不是条内那行红字（`GoalBar.tsx:99,138`）：
   36dp 的条塞不下第二行，而"失败必须说出来"这条纪律全 App 只有一个出口。
2. **受阻的 `title` 用 `Tooltip`**（触屏是长按）：HTML 的 `title` 在手机上不存在。
3. **条高落成 `minHeight: 36`**，不是定高：字号放大后（`subsystems/type-scale.md` §5）
   定高会把文字裁掉。标准字号下量到的就是 36（`goal_bar_test.dart` 钉住）。
4. **底部预算让出空间**：目标条出现时 `_BottomBudget` 的 `reserved` 加
   `kGoalBarBlockHeight`（36 + 下边距 6），否则接管卡 + 候选面板 + 目标条三者相加会顶出屏幕。
5. **动作钮是 28×28，低于设计文档 §触摸目标 的 44dp**：条高被 DSH 定死在 36
   （`GoalBar.module.css:29`）、条内上下各 4px 内边距 —— 28 是 36 里放得下的最大值
   （DSH 自己也是 28，那是鼠标）。要 44 就得把条加高，属于"手机不是缩小版桌面"的另一条路，
   这一版没走；三个钮之间有 10px 间隙（`.actions { gap: 10px }`），降低点错隔壁的概率。

## 7. 验证

| 命令 | 覆盖 |
|---|---|
| `cd app && flutter test test/goal_bar_test.dart` | **29 项**：解析三态、`AppModel.goal`、四个命令行、阶段/动作可见性、36dp、行内编辑（焦点 / 保存 / 取消 / 换行折叠）、三个失败分支、清除即隐、`goal/change` 重读、形状漂移留声、翻页不落条目、chat_page 里"目标条在排队条之上" |
| `cd app && flutter test test/wire_shapes_replay_test.dart` | `goal` 键按**连接器金样**回放（两层：`values.goal` 与 `values.goal.goal`） |
| `node app/tools/verify-platform-boundary.mjs` | 改 `app/lib` 必跑 |

真机（`d61cf622`，2026-11-04，dsh-test 里的一个会话）：`/goal say OK` → 条出现
（进行中的目标 · say OK）→ 点暂停 → 已暂停的目标 + 恢复钮 → 点恢复 → 进行中的目标 +
暂停钮 → 点清除 → 条立刻消失。`/goal bar edit check` 建目标 → 编辑 → 打字（焦点在编辑框，
不再漏进输入栏）→ 保存 → 条上正文变成 `bar edit checkXY` → 清除。命令卡在那一轮的折叠过程里可见。

金样侧的 `goal` 值在 `connector/tests/support/fixture-handlers.ts` 的
`FULL_PROJECTION_VALUES`（15 个键），由 `connector/tests/wire-shapes.test.ts` 生成并守住。

## 8. 已知边界

- **没有 `GoalActivation`**（§2）：所以"active 但已 disarmed"这一档在手机上显示成
  「进行中的目标」+ 暂停钮。真相在电脑侧，要拿到它得给连接器加 `goal.*`。
- **`roundsStarted` / `maxGoalRounds` 不画**：DSH 的条也不画（它只在 `/goal` 的
  命令回执里说 `Rounds: 3/256`）。字段解析了但今天没有消费方。
- **`/goal <objective>` 建目标不在条上**：DSH 同一条 —— 新建走输入框那条命令。
- **命令卡**（§4）：每次点动作都会在对话流里多一张 `/goal` 的命令卡。
- **动作发出后立刻切会话**：命令按发送那一刻的当前会话落地（`executeCommand` 读
  `AppModel.currentSid`），条子自己不持有 sid。窗口是"点了到应答回来"那几百毫秒，
  后果是那条命令落到另一个会话上（`/goal pause` 在没目标的会话里回一句
  `No goal is currently set`）。要同时做两个动作才碰得到，没有为此加参数。
