# Agent Note: 候选面板照宿主做成列表行（分组 + drill + 面包屑）

Status: implemented

## Problem

`@` / `/` 的候选面板是**居中的一排胶囊**（`Wrap` + 一个只有 label 的 chip）。宿主的候选菜单
不是这个形状：`packages/client/ui-input-trigger/src/client/MenuView.tsx` 的 `.item` 是
**占满宽度的列表行** —— 图标 + 名字 + 右侧说明 + 目录行末尾的 chevron，上面还有分组标题
（`文件与文件夹` / `对话` / `指令`）；目录行有第二个动作（drill 进下一层），drill 之后出现面包屑
（`ui-reference/src/client/index.ts:131-149,199-226`）。

胶囊带来的不是"朴素一点"，是**信息没地方放**：父目录没有一列可写、目录没法进去、分组不存在、
`/` 的命令没有说明可显示。用户第一句反馈就是"居中的，为啥不是目录那种"。

## Decision

面板按**宿主的列表行**重做，`@` 与 `/` 共用一个实现（`_SuggestionPanel` + `_PanelRow`）：

1. 浮在输入卡**上方**、与卡同宽（`.menu` 的 `bottom:calc(100% + 4px); left:0; right:0`）；
2. 分组标题用宿主的 zh 原话（`文件与文件夹` / `对话` / `指令`），不另起中文；
3. 一行 = 图标（目录 `folderClose`、文件 `browse`、会话 `queue`，与宿主的三种 artwork 逐字对应）
   + 名字（目录带尾斜杠）+ 右侧说明（父目录，drill 之后不重复）+ 目录行的 chevron；
4. 目录行两个动作：点行体 = 落定（插入 `@path/` 并关面板），点 chevron = drill（同样插入，
   **面板不关**，按新查询列子项）；
5. 面包屑只在 **drill 之后**出现（`drilled` 是"这一屏是钻进来的"，不是"路径里有斜杠"）；
6. pending 给两行骨架（32% / 48%），空 / 失败仍是一句话。

准入门槛（可机械判定）：

1. 行是**左对齐且撑满面板**：`row.left < panel.center.dx` 且 `row.width ≥ panel.width − 20`；
2. 目录行的 chevron 与行体**两个结果**：点 chevron 后输入框变 `@src/` 且面板仍在、
   点行体后输入框变 `@src/` 且面板消失；
3. 面包屑的判据是 `drilled`：**手打** `@src/` 不出面包屑；drill 之后出现 `工作区 / src`；
4. 分组标题逐字等于宿主 zh 词典（`section.files` / `section.sessions` / `command`）。

## Alternatives considered

1. **面板里做内联展开的树**（父行点开在下方缩进列出子项）
   - 最强的理由：一屏之内能同时看见父级与子级，不用一遍遍进出；深路径一趟就能点到。
   - 为何被否：宿主是 **drill** 不是 inline tree（`onPick` 的 `{text, continue:true}` 把
     正在读的文本换成更深一段），做树就是**新造一个宿主没有的语义**；而且树会让"落定这个目录"
     与"展开这个目录"两个动作落在同一行上，比 chevron 更含糊。真要做得先改 `docs/` 并留"有意偏离"。
2. **保留胶囊，只把整排改成左对齐**
   - 最强的理由：改动最小，视觉上就不居中了。
   - 为何被否：胶囊只装得下一个 label。父目录、图标、分组、chevron 都需要位置 —— 那正是
     宿主用行而不是胶囊的原因；把四样东西塞进胶囊只会变成一条挤不下的行。
3. **真浮层**（页面级 `Stack` + `position:absolute`，完全不参与布局）
   - 最强的理由：与桌面端 `position:absolute` 完全一致，面板不会把会话区挤小。
   - 为何被否：`Stack` 里溢出父边界的子节点**收不到点击**（命中测试按父节点尺寸裁），
     要做真浮层得用 `OverlayEntry` + 量输入卡高度；而"浮在卡上方、与卡同宽"这个观感
     用内联面板 + 底部预算已经达成，且约束是可测的。
4. **保持 132px 的固定上限**（上一轮为了不撑爆那一列而加的数）
   - 最强的理由：简单、绝不会溢出。
   - 为何被否：那个数是**为了不溢出**挑的，不是按可读性挑的；高度该来自"输入卡上方真正
     剩下的空间"（见 `2026-10-25-bottom-budget-and-takeover-card.md`）。

## Consequences

- 收益：观感与宿主同形（左对齐、分组、说明右对齐、drill + 面包屑）；`@` 与 `/` 一处形状；
  `/` 的行多了宿主的说明列（数据来自 `repo.info.commands`，见
  `2026-10-25-command-descriptions-from-host.md`）；面板高度上限不再是魔数。
- 代价：多一个 `_drilled` 状态与 drill / crumb 两条回调路径；面板移到卡片**外面**后
  卡片高度不再包含面板，底部预算要把两块分开算（这正是第三篇笔记要解决的问题）；
  chevron 的触达区 30×22 仍小于 44×44 的触屏惯例（比桌面的 18×18 大，点偏会落到行体上）。

## 真机验证（2026-10-25）

仪器：`d61cf622`（23113RKC6C，root），隔离实例 `DSH_HOME=D:\tmp\dsh-e2e` +
`mobile-e2e` profile（63900 / 直连 8790）+ 本机中转 8787（`adb reverse`）；
APK 是当前 HEAD 的 debug 包（`adb install -r`，配对凭据保留）。
截图与语义树在 `D:\tmp\dsh-e2e\`（`a-01…a-11`、`s-01`）。

- **列表行 / 分组 / 图标**：`@` 面板贴着输入卡上方、与卡同宽，左对齐行、行首图标、
  section 标题两档实际文案是 **`文件与文件夹` / `对话`**（宿主 zh 词典 `section.files` /
  `section.sessions` 的原话，不是开工单里简写的"文件 / 会话"）；`/` 面板 section 是 `指令`。
- **高度与滚动**：面板底部停在输入卡上沿，超出部分在列表内滚（`app/lib/ui` 35 个文件只
  一屏放得下 7 行，实测两次滑动后可见 `dsh_popover…input_focus`）。**没有**滚到底的渐变提示
  （开工单列为可选，未做）。
- **drill**：点 `app/` 行尾 chevron ⇒ 输入框变 `@app/`、**面板不关**、面包屑出现
  `工作区 › app`；再钻 `lib/`、`ui/` ⇒ `工作区 › app › lib › ui`；点最左的 `工作区` ⇒
  回根层、面包屑消失、输入框回到 `@`。宿主同一条（`crumbsFor` 只在 drill 后给）。
- **落定**：点 `app/` **行体** ⇒ 输入框 `@app/` 且**面板关闭**；点会话行（`Reply with fixed text`）
  ⇒ 输入框是宿主原样的 `@[Reply with fixed text](dsh-session:…)`，选择规则一个字没动。
- **名字列 40% 截断是真机可见的**：会话行 `Spawn grandchild, re…` 右边还有半个屏的空白。
  这不是实现走偏 —— 宿主 `.itemName { max-width: 40% }`（`MenuView.module.css:103-109`）
  就是这个数；手机上 40% 的绝对宽度更窄，观感差异来自屏宽不是实现。
- **会话行没有右侧说明**：宿主是 `位置 · 相对时间`，我们是空的 —— `refs.sessions` 只回
  `{sid,title,mention}`（`app/lib/model/mention.dart:125-135` 已注明）。**仍是缺口**，
  要补就得让 `refs.sessions` 带上位置与更新时间（`session.list` 里两样都有）。
- **没验到的两态**：pending 骨架（本机往返几十毫秒，`screencap` 起不来时就结束了）与
  失败态（要停实例）。两者都只有 widget 测试证据。
