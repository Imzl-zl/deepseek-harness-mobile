# Agent Note: 子会话的**父级与 mode 由画出那一行的那一层交出**

Status: implemented（2026-10-23）。

## 起因

审查清单 I2（`proposed/2026-10-23-subagent-parent-and-model-truth-review.md` §2）：
`_switchSibling` / `_openSubagent` 都拿**已经持有的那一行**的 id，回目录里再查一次
`mode`；`_switchSibling` 还要**全表扫描**反推父级
（`subagentParentOfCatalogEntry(node.id) ?? _subagentParentSid`）。

症状：切换面板里展开一个读过的子级 → 那一层**无条件重读**（`subagent_tree.dart` 的
`onLoad`）→ `AppModel._readProjections` 先把目录置成 `loading`（**保留旧 entries**，
所以界面照常画行、也点得动）→ 这一拍里点孙级：扫描**只认 `ready`**（`app_model.dart`
的 `continue`）⇒ 返回 `null` ⇒ 退到"当前会话的父级"（祖父）⇒ 祖父目录里没有孙级
⇒ `_subagentMode = null` ⇒ 可续聊的孙级显示「此子智能体暂时只读」，而且**不会自愈**
（mode 只在进入那一刻取一次）。网络慢时这个窗口是秒级。

根因不是"少一个兜底"，而是**父级与 mode 都从别处猜**，而它们都在手上：
`SubagentNode.row` 就是目录那一行（`SubagentRow.mode` 是非空 `String`）。

## DSH 的形状：地址在画行的那一层构造

- `openChild({parentSessionId, childSessionId: entry.id, mode: entry.mode})`
  （`packages/client/ui-subagent/src/client/SubagentHeaderLineage.tsx:279-287`）——
  **父级与 mode 都来自那一层**，不查表。
- 层级递归把 `entry.id` 传给下一层当 `parentSessionId`（同文件 `:386`），
  所以"这一行的父级"就是"画出它的那一个目录的 sid"。

我们的 `onOpen(node)` 丢掉了这两样，才需要扫描。

## 决定

1. `SubagentTree.onOpen` 改成 `void Function(SubagentNode node, String parentSid)`；
   `_Level` 调它时传自己的 `sid`（`subagent_tree.dart` 的 `_node`）。
2. `_openSubagent` / `_switchSibling` 都用传入的父级写 `_subagentReturnFrom`，
   `_subagentMode = node.row.mode` —— 删掉两次目录回查。
3. `subagentParentOfCatalogEntry` 只剩 `_subagentParentSid` **第 2 档**一个调用点，
   并加 `entry.key != sid` 的自引用守卫（畸形投影里"自己是自己的子级"会让 `←`
   原地重进自己）。

## 代价与边界

- **只读档仍然看导航记忆**（`_subagentReturnFrom` / `_subagentMode` 一起写）：
  I2 只改"mode 从哪来"，不改"恢复出来的子会话不判只读"这条分工
  （见 `2026-10-23-subagent-header-parent-from-data.md` 的「代价与风险」）。
- **第 3 档记忆不能删**：新手机连老连接器时 `parentSessionId` 为空，删了就没有
  `←`。`subagentParentOfCatalogEntry` 仍然服务这一档。
- **`_subagentReadOnlyReason` 的 `== null` 半支不可达**（记忆非空 ⇒ mode 必有值），
  留着并注明它是**默认拒绝**的那一侧：`_subagentMode` 是 `String?`，将来若有别的
  入口只写记忆不写 mode，这一支会把输入禁掉（fail-closed），而不是凭空放行。
- 源码净减 **15 行**（chat_page −23、subagent_tree +4、app_model +4）。

## 判据

- `app/test/subagent_enter_test.dart`「展开后那一拍里点孙级：mode 来自它自己那一行，
  不是回目录里查」：替身用 `Completer` 挂住 `session.projections` 的应答，
  在挂住期间（目录 `loading`、旧行仍在）点孙级 ⇒ **不是只读框**、输入栏还在。
  变异校验：把 `_switchSibling` 整体改回旧形状（扫描反推父级 + 回查 mode）
  ⇒ **恰好这一条**红，且红的方式正是症状本身
  （`Found 1 widget with type "SubagentReadOnlyBand"`，14 条里 13 绿）。
- `app/test/subagent_tree_test.dart`：「点行 = onOpen」新增断言父级 = `root`；
  展开后点孙级断言父级 = `child-1` —— 钉的是"父级随行交出"这个契约本身，
  与 chat_page 的实现无关。
- 门禁：`flutter test` **1121**（原 1120）/ `dart analyze --fatal-infos` 0 /
  `dart format --set-exit-if-changed` 0 / boundary **357**（98 个 Dart 文件）。

## 被否掉的替代

- **让扫描也认 `loading`**（一行改动，窗口立刻消失）
  - 最强理由：改动最小，不动 `onOpen` 的签名。
  - 为何被否：`loading` 的 `entries` 是**上一次**的内容，拿它认父级会把关系钉在旧树上
    （`app_model.dart` 里那条 `continue` 就是为这个写的）；而且真正的答案是"树知道"，
    不是"扫描放宽"。
- **在 App 侧维护一张 `child → parent` 表**
  - 最强理由：查一次就够，O(1)，不依赖目录状态。
  - 为何被否：第二份会漂的真值，重启即丢 —— `7806b2a` 已经否过同一个形状。
- **给 `_switchSibling` 的 mode 回查加一层"查不到就再看 node.row"的兜底**
  - 最强理由：不改签名，只加一次回退。
  - 为何被否：它修的是症状。回查本身是多余的（那一行就在手里），留着它就留着
    "查错目录"这一整类 bug；而且"先查 A 再退 B"会让下一个读代码的人以为 A 有时是对的。
