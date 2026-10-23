# Agent Note: 子智能体的**输入栏模型**取自行的投影提示；只读档的 mode 取自它自己那条目录

Status: implemented（2026-10-23）。

## 起因

用户 2026-10-23 看图追问：

> 「子智能体页面怎么没有显示模型啊？你说的这些应该 dsh 原生都是有的，因为我们其实就是
> web 映射到手机，所以你肯定什么没注意，细节没有注意到吧」

真机复现（`shots-2026-10-23/v4-child-header.png`）：进子会话
`Spawn grandchild, report result`，输入栏的控制行显示 **「未选择」**，而这一轮明明跑了
25.3K tok。

## 先分清两个"子智能体页面"（别改错地方）

- **右侧抽屉的子智能体面板（目录树）**：DSH 的行里**没有模型** ——
  `packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx` 里 `grep model` **零命中**，
  行的第二行是 `title · mode · activity`（`:257-259`）。我们照它，所以面板行没有模型
  **不是缺漏**。要加就是移动端的有意偏离（还没加）。
- **进到子会话的那一页**：DSH 的输入栏（composer 的 `ModelSelect`）读的是**这个会话的
  `modelSelection` 投影**，所以子会话也显示模型。我们这一格是「未选择」——这才是 bug。

## 为什么我们显示「未选择」

连接器 `session.list` 行的顶层 `model` 来自 `connector/src/dsh/models.ts` 的 `modelOf`：
别名 → DSH id → **`agents.get(id)?.session`** → `sessionProjections.stateOf(session, 'modelSelection')`。
子会话不在 `agents` 那张"活 agent"表里 ⇒ `session` 是 `undefined` ⇒ 这一行没有 `model`。
根会话/普通会话在表里，所以只有子会话这一格是空的（同一屏里父会话显示 `auto`）。

## 数据其实就在同一个包里

`session.list` 的行还带一包**投影提示**：`projections = {kind: 'cached' | 'sequenced', asOfSeq, values}`。
DSH 的 `list.ts:291-312` → `hintsOf`（`:321-329`）**不挑键**，`values` 就是那个会话的整套投影值；
我们已经从同一处取 `title` / `subagentTiming` / `tokenUsage`。
`modelSelection` 也在里面，而且**子会话一定有值**：它的 `lastUsed` 由 `request/header` 推出来
（`packages/api/session-controller/src/model-selection-projection.ts:44-51`），
子会话跑过一轮就有 `request/header`（真机会话日志里逐字可见）。

## 改法

1. `AppModel._parseSessionList`：`model` 优先解析**行的投影提示**
   `projections.values.modelSelection` 的 `next ?? lastUsed`
   （`_modelSelectionOf`，与 DSH 的线格式 `:65` 同一条），没有再退到顶层 `model`（老连接器）。
2. `chat_page.dart` 的 `_modelLabel` / `_reasoningLabel` 改走 **`AppModel.currentModel`**
   这一个出口 —— 以前两处各自 `sessionOf(sid)?.model`，模型与推理等级会各自读一份。
   模型选择面板的"当前"标记本来就走 `currentModel`，所以一处修好三处对。
3. **顺带修掉本轮自己引入的回归**：从面板往下钻时 `_switchSibling` 用"当前会话的父级"
   去查那一行的 `mode` ⇒ 孙级的行在**子级**的目录里、不在祖父的目录里 ⇒ 查不到 ⇒
   一个可续聊的孙级被显示成「此子智能体暂时只读」（真机 2026-10-23 抓到：`w6-grandchild-model.png`）。
   现在父级取"**产出这一行的那条目录**"（`subagentParentOfCatalogEntry(node.id)`），
   退到"当前会话的父级"。

## 代价与边界

- 没有新增往返：`modelSelection` 就在**已过线的那一包投影提示**里，解析多一个键而已。
- 投影提示是**快照**（`cached` / `sequenced`）：冷会话给的是落盘缓存里的最后一次选择，
  与 Web 列表读的是同一条（`sessions/manager.ts:678` 的 `applyListBlock`）。
  刚切完模型但还没重读 `session.list` 时，这一格会比电脑侧慢半拍 —— 与标题、token 同一条边界。
- 顶层 `model` 仍然保留为**第二档**：老连接器没有投影提示，或者提示里没有这个键时用它。
- 没做的事：**面板行不显示模型**（DSH 不显示）。要加是移动端的有意偏离，需要单独一条决定。

## 判据

- `app/test/session_list_wiring_test.dart`「模型优先取行里的投影提示 modelSelection」：
  子会话行（只有投影提示）→ `m-next`；`next: null` → `lastUsed`；没有提示 → 顶层 `model`。
  变异校验：把 `_modelSelectionOf(...) ??` 去掉 ⇒ 恰好这条与下面那条红。
- `app/test/subagent_enter_test.dart`「子智能体页面的输入栏要显示模型」：
  父会话（行里没有 `modelSelection`）仍是「未选择」，进子会话后显示 `m-child-0`。
  同一文件「父→子→孙」新增两条断言：进孙级后是「一次性子智能体记录」，
  **不是**「此子智能体暂时只读」（钉 mode 的来源是它自己那条目录）。
  变异校验：把 `_switchSibling` 的父级改回 `_subagentParentSid` ⇒ 恰好那条红
  （`Found 0 widgets with text "一次性子智能体记录"`）。
- 真机（同一隔离实例，只换 App 包）：`w5-child-model.png` / `w8-child-model.png`（子会话 `auto`）、
  `w9-grandchild-model.png`（孙级 `auto` + 正常输入栏）、`w10-parent-model.png`（顶层会话仍是 `auto`）。
- 门禁：flutter **1119** / connector 586 / boundary 357 / analyze+format 0。

## 被否掉的替代

- **把 `modelOf` 改成按 id 读 `sessionController.projections`**：`session.list` 每行一包
  （全部投影，几十 KB），只为一格模型，代价比"读同一包里已有的键"高一两个数量级；
  而且 `session.list` 是连上 / 开面板就会调的方法。
- **给面板行加模型**：DSH 不显示（`ui-subagent` 零命中）；加了就是"我们比 Web 多一格"，
  得作为有意偏离单独决定，不能顺手塞。
