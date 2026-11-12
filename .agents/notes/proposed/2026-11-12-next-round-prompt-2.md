# 下一轮提示词：a11y 剩余屏 + chat_page 第二刀 + AppModel 通知簇

> 用法：新会话第一句整段复制粘贴（或直接说「读 `.agents/notes/proposed/2026-11-12-next-round-prompt-2.md` 并按它执行」）。
> **这一轮写代码**。方向与证据都已核实，不要重新论证"要不要做"；实现中发现方案不成立就**停下来回报**。
> 预期成本：**0 个模型请求**（只跑 `flutter test` / `node` 门禁，约 20 分钟机器时间）。真机可选，见 §5。

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh，中文回复）。
Flutter App + TS 连接器 + Node 中转 + 可执行协议。DSH 参考源码（只读）：
D:\sudy\github\deepseek-harness。

## 0. 先读（按顺序，别跳）

1. `AGENTS.md` —— 铁律：宿主语义优先、不猜、**改源码只用编辑工具**、非平凡改动留笔记、
   提交前看全量 `git status`、引 DSH 行为要给 `packages/...:行号`。
2. `memory.md` —— 现状快照。**注意它可能混着上一批（点对点直连）未提交的改动**，
   动手前先 `git status` 确认那批是否已提交；没提交就别碰它们、也别覆盖。
3. `tools.md` —— 门禁命令与坑。**断言的条数只看它**，别信这篇里抄的数字。
   §「隔离实例」第 11 条是 2026-11-12 真机新踩的四个坑（配对 TTL / `lan` 为空 / 中转起法 /
   粘贴载荷 / dump 会停住），要真机就走那条。
4. `.agents/notes/proposed/2026-11-11-open-findings.md` —— 清单（**第三节已按用户判定补过一条**）。
5. 上一轮（2026-11-12）的 5 篇笔记，都是这一轮的输入：
   - `implemented/2026-11-12-job-frame-parse-tests.md`（wire 边界用例；`sid` 与 `status` 两个必填）
   - `implemented/2026-11-12-caps-settlement.md`（caps 判定方法；`interaction.respond` 按两类挂）
   - `implemented/2026-11-12-a11y-sheet-and-trajectory.md`（a11y 的判据与变异口径）
   - `implemented/2026-11-12-chat-page-files-pane-move.md`（搬块的方法与棘轮收紧）
   - `implemented/2026-11-10-size-budget-ratchet.md`（`verify-size` 怎么用、怎么收紧）

## 1. 这一轮做四件（每件一个提交 + 一篇笔记；顺序即优先级）

### A. a11y 剩余屏（先修上一轮搬出来的那两个行，再按"每天点得多"排两屏）

**当前基线**：`node .agents/tools/count-a11y-candidates.mjs` 报 **57 处**"附近没有 `Semantics` 的
`InkWell`/`GestureDetector`"。**这是上界，不是清单** —— 脚本从 `InkWell(` 那行往上找 5 行，
`Tooltip` 在它上面、或 `Semantics` 在它外层时都算命中（上一轮实测假阳性约 1/3；
`trajectory_timeline.dart` 的 `GestureDetector` 现在**故意**是 `excludeFromSemantics: true`，
它的可读面在每一格的 `Semantics` 上）。**照会撒谎的清单改，等于给谎言打工。**

先做这三屏（都有真实用户路径）：

1. **`ui/files_pane.dart:197` 与 `:280`** —— 上一轮从 `chat_page.dart` 搬出来的
   「改动清单行」与「差异行」。它们现在**没有任何角色**（搬移时只搬不改行为，a11y 没跟上）。
   前者点开 diff / 文件，后者点一行**复制路径**（那是真动作，不是展示）。
2. **`ui/chat_turns.dart`**（7 处候选，先逐个人读）—— 工具卡展开、折叠组头那一类。
   判据同 `implemented/2026-11-11-fake-affordances.md`：**点了什么都不发生的就是展示**，
   改成 `onTap: null`（不接水波、不画箭头、不报按钮），不要给它加点击提示。
3. **`ui/settings_page.dart` 的行内图标钮**（2 处候选）+ **`ui/usage_page.dart`**（3 处候选）。

纪律（照 `implemented/2026-11-12-a11y-sheet-and-trajectory.md`）：
- **先读再改**，一处一处判断"这一下点了会发生什么"；
- 选择类 / 有勾选态的行要同时表达**角色与选中态**（`isSemantics(isButton: true, isSelected: …)`），
  纯图标钮必须有 **label**（`Tooltip` 不是 label）；
- 每屏一条 `isSemantics(...)` 用例，**先红后绿**；写完做一次变异（删 `Semantics` ⇒ 红）；
- **不合并子节点**（`MergeSemantics` / `excludeSemantics` 会吞掉行内其它入口，已否过一次）。

### B. `chat_page.dart` 第二刀：把剩下两块搬出去

`chat_page.dart` 现在 **4762 行 / 上限 4800**（上一轮搬走文件面板后收紧的），只剩 38 行余量。
下一刀的两块都已经读清：

- `_ChangedFilesCard`（`:4117` 起，含 `_ChangedFilesCardState`）：会话流里那张"改动 N 个文件"的卡。
  与 `ui/files_pane.dart` 同族（共用 `diffCountsOf`、读同一份 `file.changes`）—— 搬到
  `ui/files_pane.dart` 或新建 `ui/changes_card.dart`（**看搬完谁更自洽，写进笔记**）。
- `_TrajectoryTab`（`:4548` 起，含 `_TrajectoryTabState`）：轨迹页签的装配（三态 + 重读 + 空态）。
  与 `ui/trajectory_page.dart` 同族 → 搬进那个文件（它现在 662 行，搬完仍 < 800 默认上限）。

判据与纪律（同上一个搬块批次）：
- **只搬、不改行为**：搬完先跑全量 `flutter test`，**用例一条都不许改**；
- `git diff -w` 只应有搬移与"私有→公有"改名；
- 被搬走的 widget 里"为什么这样写"的注释一起带走；新文件头写清"原来在 `chat_page.dart` 的哪一段、
  为什么搬（棘轮）"；
- **收紧就是本批的产物**：`app/tools/verify-size.mjs` 里 `chat_page.dart` 收敛到 `ceil(实测, 50)`。

### C. `AppModel` 通知簇（收窄第二簇）

上一轮搬了任务簇（`data/job_book.dart`），当前 **5215 行 / 177 方法 / 上限 5250·177**。
下一簇按 `proposed/2026-10-27-ui-state-design.md` 的顺序是**通知簇**（后台任务完成通知、
审批待处理提醒、常驻通知的同步）。做法与任务簇同一条：**判据自洽的一块整体搬走**
（不是拆小文件），搬完方法数**只降**、行数棘轮收紧。

先取证再动手（照 `tools.md` 的"拆分的信号是重复的清单与缺失的所有者"）：
数一数通知那一簇有几个可变字段、几处写、有没有**两份重复的重置清单**。
没有第二份清单、也算不上"缺失的所有者"的那一块，**就不拆**（拆了只是搬家）。

### D. 文档漂移三处（各一条，判定"留 / 删 / 改文档"）

1. `connector/src/dsh/interaction-client.ts:63` import 了 `transport/backoff.js`，
   与 `docs/subsystems/connector-and-relay.md` §1.2 的「`dsh/` 不 import `transport/`」矛盾
   （memory.md 已记）。要么把那条 layering 规则连同它的测试一起改（如果这个 import 是正当的），
   要么把 import 换掉 —— **别只改文档不改代码**。
2. `plugin.installStatus` 的 4 键 / 8 键两种形态（memory.md 已记）：定一种是真值，另一种写进文档
   当"老连接器的兼容形态"，或删掉兼容分支。
3. `caps.approval`（`connector/src/dsh/caps.ts:225`）**报了但全仓没有读者**：判定它是不是
   "留给未来的字段"。判"删"就同批删掉 `caps.approval`（**会改线上 `repo.info` 的形状**，
   要同时改金样 `connector/tests/fixtures/wire-shapes.json` 与契约 §7）；判"留"就在
   `caps.ts` 那一行写一句"为什么留着"，别让它继续无声漂。

## 2. 明确不做（别当成缺口反复重开）

见 `open-findings.md` 第三节（已按用户判定补齐）。特别是：

- **缺服务时把任务/子智能体面板说成"这台电脑没有这个面"** —— 用户 2026-11-12 判定：
  **没有就是没有**，空态已经如实；再区分一层要动 tab 结构，不值。
- 不给 a11y 搞"计数门禁"（判据是语义判断，做不成机械规则）；也不一次改完 57 处。
- 不引状态管理库、不给 `core/` 加超时/重试、不把 `mock/proto` 补到和 App 一样。

## 3. 门禁（改代码后必须全绿；条数以 `tools.md` 为准，别抄这篇）

```pwsh
cd app; dart format --output=none --set-exit-if-changed lib test integration_test
cd app; dart analyze --fatal-infos lib test integration_test
cd app; flutter test
node app/tools/verify-platform-boundary.mjs
node app/tools/verify-size.mjs
node app/tools/verify-rpc-single-caller.mjs
node mock/proto/tools/verify-icons.cjs
node mock/proto/tools/verify-tool-paths.mjs
```

- 动 `protocol/` ⇒ 三条 `verify-*.mjs` 必须全绿（这一轮预期不动）。
- 动 `connector/`（D 那三处里有两处在连接器）⇒ `pnpm exec tsc --noEmit` + `pnpm build` + `pnpm test`，
  且 fixtures 断言数须 = 454、向量 = 49。

## 4. 变异校验（写用例时的必做项，顺序别反）

1. **先确认变异真的改到了代码**（`grep` 变异后的形状），再跑用例。
2. **接线用例与组件用例分开**：组件用例全绿 ≠ 它会被挂上去。
3. **用例要通过的必须是那条机制**，不是"碰巧也是 false"。
   （例：`isSemantics(isSelected: false)` 与"没有这一位"同义 —— 那种断言删掉实现也不红，别写。）

## 5. 真机（这一轮默认不用；要用先报价）

- 设备 `d61cf622`，已配对隔离实例 `D:\tmp\dsh-mobile-home`（直连 18791，中转 8787）。
  **2026-11-12 已重配过**：设备 id `zijVnu065_AozcgofVaW3A`，`lan` 已用 `advertise extra`
  标了 `ws://192.168.110.79:18791`。中转与实例都**已停**，按 `tools.md` §「隔离实例」第 10/11 条起。
- 免费模型渠道在隔离 profile 里（`magpie-free` → 本机 3425 网关，key 不需要），
  **不花官方账号的钱**；但仍遵守"本轮约 N 个轮次、先报价"。
- 只读/无模型请求的项（开 App、切页、看面板）不用报价；**要发 prompt 才报价**。
- 上一轮的内存基线：空态 ~200 MB；连开 5 个会话 219→224 MB（无线性爬升）。

## 6. 交付

- 四件各一个提交（`fix`/`refactor`/`test`/`docs` 前缀照 `git log` 既有风格），**代码与笔记同批**；
  每篇笔记按 `decision-notes` 的四格写（Problem / Decision / Alternatives / Consequences），
  并给准入判据与变异校验结果。
- 收尾时**不要**改 `memory.md` 除非用户明确同意（它现在混着上一批未提交的改动）——
  状态写进笔记，并在回报里说一句"memory.md 未动，原因 X"。
- 回报格式：每件一行「做了什么 / 判据在哪 / 变异结果 / 未做与原因」。
```
