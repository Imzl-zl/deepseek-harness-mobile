# Agent Note: 侧栏会话置顶与组内重排 —— 三条 Host 方法 + 触屏长按菜单

Status: implemented

## Problem

用户 2026-10-21 问「左侧的会话可以折叠，移动吗？web 都支持」，并纠正过一版把它
当成本地偏好的判断：「不是偏好啊，是 web 都有的功能啊」。

查实后，组折叠已有（`CollapsibleGroup`），缺的是**移动 / 置顶**。DSH 侧它们不是
浏览器缓存，而是 registry 的持久顺序：

- `workspace.insertSessionBefore({workspaceId, sessionId, beforeSessionId?})`
  （`packages/api/workspace-controller/src/index.ts:149-152` → `commands.ts:132-152`，
  请求形状 `types.ts:107-112`，DOM `insertBefore` 语义；跨工作区拒成
  `workspace/move-invalid`）。
- `workspace.pinSession` / `workspace.unpinSession`（`index.ts:179-191` →
  `commands.ts:202-227`），返回 `{pinnedSessionIds}`（`types.ts:147-150`，
  **最近置顶的在前**）。归档与置顶互斥（`commands.ts:209-211`）。

连接器的方法面里一条都没有；手机侧也没有任何行动作入口，`SessionDrawer.onDelete`
从未接线，长按一直无效。

## Decision

**三个动作都走 Host 的官方方法，手机不维护第二份顺序/置顶真值；触屏形态用行长按
菜单替代 Web 的拖动。**

1. 契约 §5.7 加三行：`workspace.insertSessionBefore` / `workspace.pin` /
   `workspace.unpin`。返回体分别是 `{sessionIds}`（该组新顺序）与
   `{pinnedSessionIds}`（置顶全集），id 都已换成手机见的 `sid`。
2. 三条都进 `IDEMPOTENT_METHODS`：它们是用户指令，重发落到同一目标态；
   与归档同一条纪律——指令层不靠宿主幂等兜底。
3. 显示顺序照 DSH 的 `sectionMembers`（`ui-workspace/src/client/tree.ts:273-287`）：
   **置顶项排在各自工作区分组的最前**，两个分区内部保持电脑侧给的相对顺序。
   置顶不是把会话抽到整张表最上面。
4. 上移/下移的门禁照 Web 拖动：置顶行只在置顶块内移动，普通行不跨过置顶块
   （`WorkspaceBrowser.tsx:593-596` 的 `drag.pinned === node.pinned`）。
   锚点计算是纯函数 `moveAnchorInDisplayOrder`：上移 = 插到前一条之前；
   下移 = 插到目标位的下一条之前，没有下一条就省略 `beforeSid`（宿主追加语义）。
5. 行动作只做「置顶 / 取消置顶 / 上移 / 下移 / 归档」。**没有删除**：
   `workspace-controller` 没有删除会话的方法，原型早期那个「删除」是假动作。

## Alternatives considered

1. **把顺序 / 置顶存成本地偏好（`dsh.workspace.view.v5` 那种浏览器缓存）**
   - 最强的理由：不用动方法面，改本地列表即可；Web 确实还有一层浏览器视图缓存
     （`stores.ts:91`），拖动后的顺序在本地先落。
   - 为何被否：用户要的是 Web 那条功能，而 Web 的持久顺序在 Host registry。
     本地缓存在换设备 / 重装后消失，且与 Web 并排打开时两边顺序不一致；
     第一版笔记把它写成本地排序，已被用户当场否掉。

2. **照 Web 做按住拖动**
   - 最强的理由：与 Web 交互完全一致，且拖动比菜单快；DSH 的拖动已有现成的
     置顶分区门禁，照着抄即可。
   - 为何被否：手机抽屉是纵向滚动的长列表，拖动会和滚动抢手势；DSH 的拖动还依赖
     hover 落点标记。长按菜单在同一目的下不会误触发，代价是"一次只能移一位"。

3. **置顶时同时调 `insertSessionBefore`，把置顶项也写进 Host 顺序**
   - 最强的理由：显示顺序只依赖 `sessionIds`，不必再解析 `pinnedSessionIds`；
     Web 的 `pinSessionOrder` 也会把会话前置到浏览器的本地顺序
     （`navigation.ts:376-384`）。
   - 为何被否：Host 的 `pinSession` 本身不改 `sessionIds`；再补一次重排会让
     "取消置顶后回原位"失去原位（顺序已被永久改写）。置顶只是显示分区，
     不应制造不可逆的顺序变更。

4. **保留原型里的「删除会话」并接到手机**
   - 最强的理由：原型已经有这个入口，用户也看得到；删掉会少一个动作。
   - 为何被否：DSH 没有这个方法。手机发不出请求，只能做成"从手机列表移除"的
     本地隐藏，而它会在重连后回来——正是"看起来成功了"的假动作。
     原型同步删掉了这个入口。

## Consequences

- 收益：置顶 / 排序与 Web 同源，重连后仍在；连接器与契约的 `workspace.list`
  现在同时给出归档集与置顶集，只换一半别名的旧坑不会再出现。
- 代价：没有拖动，移动是逐位菜单操作；置顶项之间的显示顺序仍取决于 Host 的
  `sessionIds`，不是"最近置顶的在前"（后者只用于默认排序的来源）。用户若要求
  "新置顶的永远排第一"，需要再加一次 Host 重排，那是另一个决定。
- 代价：`workspace.list` 的返回体多了一列；老连接器不返回时手机按空集处理，
  置顶功能自然隐藏（菜单仍有，但置顶后刷新会回到未置顶）。这是如实的降级。
- 修正（2026-10-21 审查当场发现）：**兜底桶不能重排**。「未分组」与"拿不到工作区
  清单时的单桶「会话」"里的会话没有 `workspaceId`，发 `insertSessionBefore` 必被
  `AppModel.moveSession` 拒、屏幕上只剩一句失败。现在 `WorkspaceBucket` 带
  `workspaceId`（`null` = 兜底），抽屉据此把上移/下移置为不可点 ——
  与"边界项保留但不可点"同一条理由。原型的不可用项也从内联 `opacity` 改成
  真 `disabled`（灰是样式，点是行为，要一起关掉）。
- 修正（同一次审查）：**宿主错误码原先根本到不了手机**。分发器只保留
  `ProtocolError` 自己的码（`protocol/methods.ts:265-275`），于是
  `ERROR_TABLE` 里那行 `workspace/session-active` 是死代码，手机看到的是
  `internal`（客户端动作 `log-and-retry`，而"会话还在跑"重试不好）。现在
  `dsh/workspaces.ts` 的 `asProtocolError` 把**表里有的**宿主码抬成同码协议错误；
  表里没有的（`workspace/move-invalid`）仍按统一规则降成 `internal` + 宿主原文
  —— 透传一个手机不认识的码比降级更糟。
- 验证：连接器 `workspaces-archive.test.ts` 13 项（含"宿主码抬升"那条）+ 全量 556 项；
  App `workspace_actions_test.dart` / `workspace_grouping_test.dart` /
  `session_drawer_test.dart`（含兜底桶不可重排，做过变异校验）；原型
  `verify-drawer.mjs` 25 项（含"不可用项点了顺序不动""长按的合成 click 不得打开会话"，
  两条都做过变异校验）。
- 真机未验：置顶在重连后仍成立、长按菜单在触屏上的手感。
