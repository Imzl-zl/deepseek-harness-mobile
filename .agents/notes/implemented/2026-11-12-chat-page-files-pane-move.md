# Agent Note: `chat_page.dart` 收窄第一批 —— 文件面板整块搬走

Status: implemented

## Problem

`ui/chat_page.dart` 是棘轮门禁里最紧的一格：**5298 行 / 上限 5300**。
上一轮两次想加组件都被它拦下（改到独立文件才过），而"拆组件"解决不了它 ——
组件拆得再细，页面本身那 5000 行还在。

真正的收窄单位是**一整块面**，不是一个个 widget。文件面板正好是这种块：

| 位置（原 `chat_page.dart`） | 是什么 |
|---|---|
| `_ChangesPane` + `_ChangesPaneState` | 「差异 / 文件」两个页签的面板体（读 `file.changes`，行点开 diff 或内容） |
| `_ChangedFileList` | 老连接器那条退路：工具调用得到的路径清单（点一行复制路径） |
| `_OpenedFileBody` | 正在看的那一份文件（三态：读失败 / 正在读 / 已读到；diff 五结局） |
| `_EmptyFilePane` | 两个页签共用的空态 |
| `_countsOf`（顶层函数） | `+N / −M` 与"二进制 / 过大"两个标记，**改动卡与侧栏共用** |

约 470 行，且它们之间**自洽**：只通过 `AppModel` 拿数据，不认识页面的手势、抽屉与路由。

## Decision

搬到新文件 `app/lib/ui/files_pane.dart`（**573 行**，仍在 800 行默认上限内，**不进预算表**）。

- **只搬、不改行为**：搬完 `flutter test` **一条用例都没改**，1867 项全绿。
  `git diff -w` 里 `chat_page.dart` 是 10 插入 / 546 删除：删的是那 470 行 + 5 个搬走后
  失效的 import，插入的是 `import 'files_pane.dart';` 与那 5 个调用点的改名 —— 没有第二条改动。
- **改名只发生在私有 → 公有这一层**（跨库引用不了私有名，这是搬移的机械代价）：

  | 原 | 现 |
  |---|---|
  | `_ChangesPane` / `_ChangesPaneState` | `ChangesPane` / `ChangesPaneState` |
  | `_ChangedFileList` | `ChangedFileList` |
  | `_OpenedFileBody` | `OpenedFileBody` |
  | `_EmptyFilePane` | `EmptyFilePane` |
  | `_countsOf` | `diffCountsOf` |

  `diffCountsOf` 是**唯一跨两个库的那个**（改动卡留在 `chat_page.dart`，侧栏在 `files_pane.dart`），
  它的文档注释原样带走 —— "两处各写一遍必然漂成卡片说 +9、侧栏说 +0"。
- 搬走的块里"为什么这样写"的注释**一起带走**：假 diff 的删除理由（2026-10-15）、
  "点一行复制路径"为什么现在才成立（2026-10-20）、diff 五种结局的桌面同源词典。
- 文件头写清"它原来在 `chat_page.dart` 的哪一段、为什么搬（棘轮）"，并回指本篇。
- **收紧就是本批的产物**：`app/tools/verify-size.mjs` 的 `chat_page.dart` 从 **5300 → 4800**
  （`ceil(实测 4762, 50)`）。`AppModel` 那一格不受影响。

## 准入判据

| 判据 | 结果 |
|---|---|
| `cd app; flutter test` | **1867 项全绿，用例零改动**（这是"只搬不改行为"的主判据） |
| `dart analyze --fatal-infos lib test integration_test` | 0（搬完暴露的 4 个 unused import / 4 个缺 `super.key` 已一并修掉） |
| `dart format --set-exit-if-changed` | 0 |
| `node app/tools/verify-size.mjs` | 19 条自检 + **chat_page 上限收紧到 4800** |
| `node app/tools/verify-platform-boundary.mjs` | 879 项（多扫一个新文件；`files_pane.dart` 在 `ui/` 下，不碰任何一条禁用面） |
| 行为覆盖仍在的那两条 | `changes_card_test` 的 `changesFailureOf(6)` 三条（失败 / 不错报）、`chat_file_mention_test` 的 `file-open-back` / `file-open-more` |

## Alternatives considered

1. **继续拆组件（把 `_OpenedFileBody` 的三种 body 各自成 widget）**
   - 最强的理由：粒度更细，单文件更小。
   - 为何被否：它不减 `chat_page.dart` 一行 —— 拆出来的组件要么仍在同一文件、要么搬走之后
     页面里那 470 行还是有别的等价块（面板体、空态）。**拆组件解决"文件太长"里的错误一半。**
2. **用 `part` / `part of` 共享同一个 library，保持所有名字私有**
   - 最强的理由：零改名、零 API 面增加。
   - 为何被否：本仓没有任何 `part`（`Select-String "part of"` 0 处）。为一处搬家引入一个新
     组织方式，代价不是这次改名，而是以后每个读 `ui/` 的人都要多认一种文件关系。
     公有名在 `ui/` 里是常态（`SidePane` / `HistoryFailureNote` / `TakeoverQueue`）。
3. **顺手把 `_ChangedFilesCard`（改动卡）也搬过去**
   - 最强的理由：它与 `diffCountsOf`、与改动记录是同一族事实。
   - 为何被否：改动卡是**会话流里的条目**（渲染在聊天流里、参与轮组折叠与事件投影），
     与"右抽屉那一块"不是同一物理位置。搬它要连带它的折叠/定位判据，超出"只搬"的边界。
     本批的判据是"搬一块**自洽**的"，不是"把同名的搬到一起"。
4. **把 470 行留在原处、只把上限提上去**
   - 最强的理由：零风险。
   - 为何被否：那就是棘轮被绕过的样子。上一轮两次被拦都写在这里：`verify-size` 的价值
     全在"不能悄悄长"，而"提上限"是可见的债；这一次能降，就该降。

## Consequences

- 收益：`chat_page.dart` **5298 → 4762 行**，上限收紧到 4800。下一批想加组件时有 38 行空间
  （仍不多，所以下一次仍是"搬一块"而不是"再拆一个 widget"）。
- 收益：右抽屉文件区的五个事实（改动清单 / 老退路清单 / 已打开文件 / 空态 / 行数标记）
  现在在同一个文件里，读一处就够。
- 代价：`ui/files_pane.dart` 新增 573 行 + 5 个公有名；`diffCountsOf` 从"文件内私有"
  变成"跨库公有"，它的调用点从 3 处变 3 处（没有增加，但可见面变大）。
- 代价：`verify-platform-boundary` 的项数从 873 变 879（多扫一个文件 × 若干规则），
  这是口径的正常变化，不是新规则。
- 未做：`_TrajectoryTab`（轨迹页签的装配）与 `_ChangedFilesCard` 仍留在 `chat_page.dart`
  —— 下一刀的两个候选，各自要先回答"它和谁同族"。
