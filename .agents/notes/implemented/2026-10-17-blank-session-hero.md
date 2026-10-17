# Agent Note: 连上电脑后落到 blank 会话，那一屏长成 DSH 的新会话页

Status: implemented

## Problem

用户 2026-10-17 的反馈是"连接后最好是电脑显示啥手机也显示啥,方便,因为就是操作电脑的",
随即把范围收窄成"我说的是**刚连上的时候的页面**,显示的不是 web 所有页面"。

手机上那一屏当时是"选一个会话"或"还没有会话"的空态,而电脑上是 DSH 的**新会话页**
(鱼 + 「探索未至之境」+ 工作区 chip + 模式 chip + 大输入框)。差距不是"少画了几个控件",
是**落点不对**:DSH 的首页由 `blank` 决定而不是由"有没有会话"决定
(`skeleton/ConversationMainPanel.tsx:41-43`),那个 blank 会话是工作区连上时被急切创建的
(`ui-workspace/src/client/navigation.ts:195-205`)。手机侧没有这一步,而且 blank 会话
**在列表里是被藏起来的**(`ui-workspace/src/client/tree.ts:245` 的
`if (session.blank && id !== current) return false`)——于是它既不在列表里、也不会被选中,
这一屏在手机上等于不存在。

## Decision

**连上后没有选中会话时,选中那个 blank 会话;当前会话是 blank 时,对话区显示 hero。**
范围只有这一屏:左/右侧栏、插件页、设置页、内嵌浏览器仍然只在电脑上。
规格见 `docs/subsystems/blank-session-hero.md`。

准入门槛(可机械判定):

1. **只在 `blank && !subagent` 的会话上显示 hero**。有内容的会话、子智能体的会话、
   以及"不知道是不是 blank"(会话不在列表里)都不显示。
2. **占位符必须是 `placeholder.hero` 那句**(「描述你想要构建的内容, / 调用指令, @ 文件或对话」),
   与普通会话那句分开。
3. **写路径只有 `session.create({workspaceId, agentPreset})`**;不新增写方法 ——
   方法面的唯一增量是只读的 `agentPresets.list`。
4. **工作区标签链的第 4 级必须回占位**:`workspace.list` 到了但没有归属时,
   **绝不**拿会话 `cwd` 的目录名顶上(那个目录可能已经被删)。
5. **断线不显示 hero**:hero 上两枚 chip 点了都要建会话,电脑不在线时该说的是"已断开"。
6. 挑不到 blank 会话时**什么都不做** —— 主界面照旧是内联会话列表。

## Alternatives considered

1. 照 DSH Web 用 `agentPresets.select(sessionId, id)` 就地改 blank 会话的预设
   - 最强的理由:与 Web **逐字同一条路径**(`ui-agent-preset/src/client/seat-store.ts:230`),
     不产生任何多余的 blank 会话,也不用把"选择"变成"建会话"这个更重的动作。
   - 为何被否:方法面要多一个**写**方法,而且它带一整套客户端状态机(staged 选择、
     refusal 提示、`agent-preset/locked` 的处置)。手机这一屏的动作本来就是"开一个新任务",
     而 `session.create` 本来就收 `agentPreset`(`/packages/api/session-controller/src/types.ts:288-293`)——
     带上它根本碰不到"跑过就锁"那条限制。代价是每换一次选择多一个 blank 会话,已记在下面。
2. 不自动落到 blank,只把 hero 挂在"用户打开一个 blank 会话"时
   - 最强的理由:改动面最小,不动"连上后落在哪"这个已经有真机结论的行为。
   - 为何被否:blank 会话在 `sessionVisible` 里被藏掉,用户**没有任何入口**打开它 ——
     等于做了这一屏却永远看不到。
3. 把 hero 做成一个独立页面(路由 / 单独一屏)
   - 最强的理由:与"列表优先"的信息架构正交,不动主界面的三支分支。
   - 为何被否:DSH 那一屏**就是当前会话的 blank 态**,不是另一个页面。做成独立页面等于
     手机上出现两处"当前会话"的表达,而且输入卡片要么跟着搬、要么出现两个。
4. 用 `session.create` 新建一个 blank 会话(而不是复用电脑侧已有的那个)
   - 最强的理由:不用先读列表,落点确定、无竞态。
   - 为何被否:电脑侧已经有一个 blank 了(工作区连上时建的),再建一个就是"每次连上都多一个会话";
     DSH 的 `reuseOrCreateBlank()` 语义也是复用优先。新建只在用户**主动选**工作区/预设时发生。

## Consequences

- 收益:连上就能看到电脑上那一屏;两枚 chip 让"选工作区 / 选预设"第一次在手机上可用
  (在此之前两者都只能在电脑上改)。方法面只 +1,且是只读的。
- 收益:hero 的鱼进了图标集(`fishLogo`),不再有"手抄一份 SVG"的第二来源。
- 代价:**每换一次 chip 的选择会留下一个 blank 会话**。blank 会话两个界面都不列,
  且 DSH 的 `reuseOrCreateBlank()` 以后会复用它,所以不随使用无限增长;
  选中的就是当前那一项时什么都不做(点一下不该多出一个会话)。
- 代价:标题 24px、chip 高 44 是**对 DSH 桌面值的触屏重算**,不是逐字照抄
  (桌面 26px / 28px)。差异与理由写在 `docs/subsystems/blank-session-hero.md` 的表里。
- 代价:"连上后落在哪"从此多一条规则(`_openBlankSessionIfUnselected`),
  它跑在每次 `refreshSessions` 之后;挑不到 blank 时行为与之前完全一致。
