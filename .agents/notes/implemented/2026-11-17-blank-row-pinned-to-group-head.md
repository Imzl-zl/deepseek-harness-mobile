# Agent Note: 新建会话那一行钉在组首，靠显示层分区而不是账本序

Status: implemented

## Problem

2026-11-17 用户反馈：手机上点「新建会话」能建出来，但那一行**不在工作区会话的第一个**。

会话本身没坏 —— 建成功了、也打开了。坏的是**组内顺序**：抽屉与主界面内联列表都按
`workspace.list` 的 `sessionIds`（账本行序）排（`bucketSessionsByWorkspace`），而桌面端
默认不是这么排的：

- 基序按 `updatedAt` 倒序（`orderBy: 'updated'`，`packages/client/ui-workspace/src/client/stores.ts:86`
  → `WorkspaceBrowser.tsx:1003-1004` → `orderByRecency`，`tree.ts:150-164`）；
- **当前那个 blank 会话被钉到组首**（`pinCurrentBlank`，`tree.ts:213-219`），
  blank 行也一律排前（`sectionMembers`，`tree.ts:269-283`）。

账本序为什么给不出"在第一个"：点「新建会话」时先**复用**账本里已有的 blank
（`AppModel.findBlankSession`），而那一行的账本位置是它**当初被建出来时**的位置 ——
DSH 打开工作区就会急切建一个 blank，所以它可能早于这一组里所有会话。只有真正新建的
才会被 `attachSession` 插到账本最前（`packages/workspace/workspace/src/entity.ts:147-149`）。

## Decision

组内分区收进 `bucketSessionsByWorkspace` 一处，次序照 `sectionMembers`：
**blank → 置顶 → 其余**，三段各自保持传入顺序。`isBlank` 是**必填**参数
（走 `AppModel.sessionBlankOf`，与抽屉可见性、watermark 同一道门）。

"blank 打头"就是桌面那条"当前 blank 钉首"：手机可见集里最多一个 blank ——
非当前的 blank 已被 `sessionVisible` 挡掉（`tree.ts:241`）—— 两条规则在可见集上等价，
所以不需要再单独传 `currentSid`。

**钉住的代价落在"可重排序列"上**：blank 行不在 `DrawerSection.reorderableIds` 里
（`[for (final s in sessions) if (!s.isBlank) s.sid]`），菜单的上移/下移与拖动都只认这一段。
于是它自己怎么移都是原地；紧挨着它的那一行也上不去（越过它 = 原地）；拖动也落不到它上面 ——
松手按"最后扫过的那一格"提交，与拖到行间同一条。

拖动要在**两处**挡：`onWillAccept`（别接受这次放下）+ `onMove`（别把插入线画到它身上）。
后者不是防御性代码：Flutter 对被拒的 target 也回调 `onMove`
（`packages/flutter/lib/src/widgets/drag_target.dart:932-945`：先 `_enteredTargets.add`，
再问 `didEnter`，然后对全部 entered 报 move）。只在 `onWillAccept` 里拦是空转 ——
2026-11-17 实测：守卫加上去，线照样画在 blank 行上。

准入门槛（可机械判定）：

1. 单测 `app/test/workspace_grouping_test.dart` 三条：blank 打头 / blank 压过置顶 /
   不分组时同样打头。
2. 组件测试 `app/test/session_drawer_test.dart` 三条：blank 行自己的上移/下移不可点；
   紧挨着它的那一行上不去、下移照常；拖到它身上时线不落到它上面、松手按最后扫过的
   那一格插（`movedTo == 'a'`）。
3. **变异校验**四条，各恰好红对应的那几条：
   - 删掉 `partition` 里 blank 那一段 ⇒ 分组测试恰好 3 条红，其余全绿
     （2026-11-17 实测：`+8 -1` / `-2` / `-3`）；
   - `display` 改回"含 blank 的全量顺序" ⇒ 抽屉菜单那 2 条红；
   - 去掉 `onMove` 的落点门 ⇒ 拖到 blank 那条红在"线不落到它身上"；
   - 去掉 `_canAccept` 的落点行守卫 ⇒ 同一条红在 `movedTo == 'a'`（得到 `null`）。
4. `isBlank` 是必填参数 ⇒ 新调用点不传就编译不过，规则不会被下一个调用点漏掉。
   **已知缺口**：`main.dart` 传的是不是真判据（`sessionBlankOf`）只有类型兜底 ——
   把它换成 `(_) => false` 仍然全绿；要真守住得有一条从 AppModel 到抽屉分区的端到端用例，
   这次没做（`workspace_ledger_probe_test.dart` 只覆盖 AppModel → 分区这一段）。

## Alternatives considered

1. 按 `updatedAt` 倒序排（照桌面默认的 `orderBy: 'updated'`）
   - 最强的理由：与桌面默认显示**完全一致**，连"回复过的会话跳到组首"也对上了。
   - 为何被否：手机的组内顺序写在宿主账本里（拖动 / 上移下移发
     `workspace.insertSessionBefore`，见 `docs/subsystems/session-ordering.md` §1），
     改成时间序后拖完立刻被时间序盖回去。要两者同时成立得再加一个"手动 / 最近更新"
     排序开关（桌面就是这两档菜单）—— 那是产品决定，不是这次修复的范围。
2. 建会话 / 复用 blank 时把它 `insertSessionBefore` 挪到账本最前
   - 最强的理由：电脑侧也立刻看到它在前，一处写、两端一致，不必在显示层做特例。
   - 为何被否：这是**替用户改他排好的顺序**，而桌面自己不做这件事（它只在显示层钉首）。
     复用一个几天前的 blank 时尤其会打乱用户手动排过的位置。
3. 只在装配层（`main.dart` 的 `_drawerSections`）把 blank 提到最前
   - 最强的理由：改动最小，纯函数签名不用动，风险面只在抽屉。
   - 为何被否：分区规则只有一份（`bucketSessionsByWorkspace`），内联列表调的就是它 ——
     把特例写在装配层等于同一个函数有两套调用约定；那一屏今天恰好没有 blank
     （`isCurrent` 恒 `false`），一旦哪天要显示当前会话就会分叉。代价也没省：
     装配层拿到的仍是"账本序的 sid 列表"，提首还得自己再判一次 blank。

## Consequences

- 收益：新建或复用的 blank 会话永远在组首，与桌面同一条；分区规则只有一处
  （`bucketSessionsByWorkspace`），抽屉与内联列表自动一致。
- 代价：组内显示顺序**不再等于账本行序**。拖动/上移下移仍写账本，但 blank 行被钉住 ——
  它不在可重排序列里，自己移不动，紧挨着它的那一行也上不去（与桌面 `pinCurrentBlank`
  同一条：那边拖到 blank 上方同样会弹回原位）。
- 仍未对齐：非 blank 会话之间手机按账本序，桌面默认按最近更新；要这条得先做排序开关。
- 尺寸预算：`app/lib/ui/session_drawer.dart` 已在上限 1400 行，这次为它腾了行
  （`verify-size.mjs` 一度拦下 1408 行）—— 该文件下次再加东西要先把注释收一收。
