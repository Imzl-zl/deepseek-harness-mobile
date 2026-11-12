# 下一轮提示词：补 wire 边界的用例 + caps 收口 + 面板搬出去

> 用法：新会话第一句整段复制粘贴（或直接说「读 `.agents/notes/proposed/2026-11-12-next-round-prompt.md` 并按它执行」）。
> **这一轮写代码**。方向与证据都已核实，不要重新论证"要不要做"；实现中发现方案不成立就**停下来回报**，别硬做。
> 预期成本：**0 个模型请求**（不跑真机、不发 prompt；只跑 `flutter test` / `node` 门禁，约 15 分钟机器时间）。
> 第 3 项可选，若要真机验，**先报价拿准**再动。

---

```
项目：dsh-mobile（D:\sudy\myproject\dsh-mobile，Windows / pwsh，中文回复）。
Flutter App + TS 连接器 + Node 中转 + 可执行协议。DSH 参考源码（只读）：
D:\sudy\github\deepseek-harness。

## 0. 先读（按顺序，别跳）

1. `AGENTS.md` —— 铁律：宿主语义优先、不猜、**改源码只用编辑工具**、非平凡改动留笔记、
   提交前看全量 `git status`、引 DSH 行为要给 `packages/...:行号`。
2. `memory.md` —— 现状快照 + 已知缺口。
3. `tools.md` —— 门禁命令、真机联调配方、Pitfalls。**断言的条数只看它**，别信这篇里抄的数字。
4. `.agents/notes/proposed/2026-11-11-open-findings.md` —— **本轮的输入**：
   已修 12 条、开着 10 条、明确不做 6 条、方法与口径 5 条。
5. 需要时再读这几篇（都短）：
   - `implemented/2026-11-11-session-memory-compaction.md`（会话正文压缩的四个边角）
   - `implemented/2026-11-11-job-output-buffer.md`（任务输出缓冲的两条判据）
   - `implemented/2026-11-11-history-failure-visible.md`（"判据没有界面消费者"那类病）
   - `implemented/2026-11-11-fake-affordances.md`（假入口的两种形态）
   - `implemented/2026-11-10-size-budget-ratchet.md`（`verify-size` 怎么用、怎么收紧）

## 1. 这一轮做四件（每件一个提交 + 一篇笔记；顺序即优先级）

### A. `core/job.dart` 的帧解析补直接用例（覆盖率 51%，`parseJobFrame` 整段没有测试）

**为什么**：它是 job 面的 **wire 边界**（连接器 → 手机的唯一入口），而 `flutter test
--coverage` 显示 51%（`parseJobFrame` / `_parseRow` / `_requireInt` 整段未覆盖）。
上一轮刚改了这一层的**消费方**语义（重开流替换而非追加），边界本身却只有间接覆盖。

**做什么**：`app/test/job_frame_parse_test.dart`，照 `parseJobFrame` 的四支逐个钉：

- 四种 kind 的正样本（`opened` / `output` / `status` / `error`）各一条，字段**逐项断言**；
- 坏载荷**必须抛**而不是猜：载荷不是对象、缺 `jobId`、`kind` 不认识、`chunks` 不是数组、
  `at`/`next`/`startedAt`/`outputTotal` 不是整数；
- **默认值纪律**：`_parseRow` 对 `status` / `kind` / `label` 是有兜底的（非 String ⇒
  `'running'` / `''`），把**这条兜底写成断言**，并在注释里说明为什么它与"认不出就抛"不冲突
  （兜的是**展示字段**，不是身份字段）。如果你认为其中某个字段也该抛，**先停下来问**，
  别顺手改语义。
- `output` 帧里 `gapBefore` / `lossy` / `channel` 的三种取值各一条。

**完成判据**：`core/job.dart` 覆盖率 ≥ 85%（`flutter test --coverage` 后按 `LH/LF` 看）；
变异校验至少一条（把 `jobId` 的空串检查删掉 ⇒ 对应用例红）。

### B. `caps` 收口 —— 判据是"会不会引发注定失败的调用"，不是"还剩几个键没读"

**已知**：`caps.jobs` 上一轮补了（`implemented/2026-11-11-jobs-capability-gate.md`）。
剩下 `caps.subagents` / `approval` / `questions` 未解析。**不要照单全补**：先回答一个问题 ——
每个能力位缺失时，手机会不会**发一次注定失败的调用**？

**做法**：在白板上把三件事逐条对照（写进笔记，不用改代码也能得出结论）：

1. 连接器缺该服务时**挂不挂**对应方法（`connector/src/handlers.ts` 的 `if (deps.X)`）；
2. 手机有没有**无条件**调它（`app/lib/data/app_model.dart` 的 refresh 族 + `host_state.dart` 的登记表）；
3. 缺了时**界面说什么**（空表 / "未读到" / 报错）。

只修第 2 条成立的那种。**如果三条都不成立，就在笔记里写明"不需要能力位"**——
那种结论同样是产出。

**同一批顺手做这一件**（上一轮留下的）：`_jobsAvailable` 默认 `true`，所以"还没读到
`repo.info`"时开一个会话仍会发一次 `job.list`。在缺 jobs 的部署上**第一次**仍会假失败一次。
修法二选一，先取证再定：

- (a) 把 `openSession` 的 jobs 触发挪到 `repo.info` 到达之后（改 `host_state.dart` 登记表的顺序语义）；
- (b) 未知时**不发**，由 `refreshRepoInfo` 成功后补拉一次当前会话的 jobs。

选哪个要写清代价（(a) 会影响所有 key 的触发时机；(b) 多一个"补拉"路径）。

### C. a11y 按屏推进（每屏一条 `isSemantics` 用例；发现"本来就该纯展示"的改成不可点）

已覆盖：抽屉行/菜单项/展开、顶栏与侧栏图标钮、composer 的 chip/发送/附件、设置行。
这一轮做**两屏**，按"每天点几十次"排：

1. **对话框 / sheet 的行**（`ui/dsh_sheet.dart` 的 `DshPickerRow` 与连接对话框）——
   注意 `DshPickerRow` 有 `selected` / `enabled`，语义要同时表达角色与勾选态
   （`isSemantics(isButton: true, isSelected: …)`），**别把"当前项"只画成打勾**。
2. **轨迹页**（`ui/trajectory_page.dart` / `trajectory_timeline.dart` 的行与时间轴段）。

纪律（上一轮踩过的）：

- **先读再改**。有一个扫描脚本报"10 处无名图标钮"，逐个人读下来只有 2 处是真的
  （`Tooltip(` 在 `InkWell(` 上面，脚本从 InkWell 那行开始找）。**照会撒谎的清单改，
  等于给谎言打工。**
- 每屏一条 `isSemantics(...)`，**先红后绿**；写完做一次变异（删 `Semantics` ⇒ 红）。
- 发现"这一行点了什么都不会发生" ⇒ 按 `implemented/2026-11-11-fake-affordances.md` 的
  做法改成 `onTap: null`（不接水波、不画箭头、不报按钮），**不要**给它加点击提示。

### D. `chat_page.dart` 5300 行收窄第一批：文件面板搬出去

**为什么**：`verify-size` 把它钉在 5300 行（只降不升），上一轮加一个新组件就被拦下来两次。
真正的解法不是拆组件，是把**一整块面板**搬走。

**搬哪块**：`_ChangesPane`（`:4592`）/ `_ChangedFileList`（`:4729`）/ `_OpenedFileBody`
（`:4806`）/ `_EmptyFilePane`（`:5000`）—— 到 `_TrajectoryTab`（`:5064`）之前为止，
约 **470 行**（文件 diff、"改动 N 个文件"的卡片壳、空态）→ 新建 `ui/files_pane.dart`。
（行号会漂，按类名定位。）

判据与纪律：

- **只搬、不改行为**。搬完先跑全量 `flutter test`，**用例一条都不许改**（`_ChangedFilesCard`
  的 `app.changesFailureOf` / `changesAvailable` 这两条判据要原样带过去）。
- 搬完 `verify-size` 会红并要求你把上限收紧（`chat_page.dart` → 新的 `ceil(实测, 50)`，
  `AppModel` 不受影响）。**收紧动作就是这一批的产物**，别只是绕过。
- 如果搬完发现新文件超 800 行默认上限 ⇒ 说明还要再切一刀（例如 diff 渲染单独一个文件），
  那就切，别把它加进预算表。
- 被搬走的 widget 里凡是"为什么这样写"的注释一起带走；`files_pane.dart` 的文件头要写清
  "它原来在 `chat_page.dart` 的哪一段、为什么搬（棘轮）"。

## 2. 明确不做（别当成缺口反复重开）

见 `open-findings.md` 第三节那 6 条。尤其：

- 不给 a11y 搞"计数门禁"——判据是语义判断，做不成机械规则；
- 不引状态管理库、不把原型补到和 App 一样、不给 `core/` 加超时/重试；
- 不一次性改完 50 处可点区（会有一部分本来就该是纯展示）。

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

- **改了 `protocol/` ⇒ 三条 `verify-*.mjs` 必须全绿**（这一轮预期不动）。
- **改了 `app/lib/` ⇒ `verify-size` 与 `verify-platform-boundary` 必须绿**。
- `connector/` / `relay/` 这一轮预期不动；动了就按 `tools.md` 跑它们各自的门禁。

## 4. 变异校验（写用例时的必做项，顺序别反）

1. **先确认变异真的改到了代码**（`grep` 变异后的形状），再跑用例。
   上一轮三次"变异没红"里有两次是替换串没匹配上 `dart format` 之后的代码 ——
   那不是"覆盖不到"，是变异没落地。
2. **接线用例与组件用例分开**：组件用例全绿 ≠ 它会被挂上去。
   上一轮把 `historyFailure: app.historyFailure` 改成 `null` 时，只测组件的两条照样绿。
3. **用例要通过的必须是那条机制**，不是"碰巧也是 false"。
   上一轮"改动记录缓存"第一版断言 `changesStateOf(7)`（键取当前会话），**不清缓存也绿**。

## 5. 真机（这一轮默认不用；要用先报价）

- 设备 `d61cf622`，**已配对隔离实例** `D:\tmp\dsh-mobile-home`（直连 18791，中转 8787）。
  实例与中转上一轮已停 —— 要跑就按 `tools.md` 的「隔离实例」起（含本轮新增的三条坑：
  Gradle 解压残骸 / 覆盖装 APK 用同一 versionCode + `-d` / 禁全部输入法再 `input text`）。
- 免费模型渠道在隔离 profile 里（`spark-x2.6`），**不花官方账号的钱**；
  但仍遵守"本轮约 N 个轮次、先报价"。
- 上一轮的内存基线（供对比）：空态 ~200 MB；连开 5 个会话 219→224 MB，**无线性爬升**。

## 6. 交付

- 四件各一个提交（`fix`/`refactor`/`test`/`docs` 前缀照 `git log` 的既有风格），
  **代码与笔记同批**；每篇笔记按 `decision-notes` 的四格写（Problem / Decision /
  Alternatives / Consequences），并给准入判据与变异校验结果。
- 收尾时**不要**改 `memory.md`（它现在混着上一批未提交的改动）—— 把状态写进笔记，
  并在回报里说一句"memory.md 未动，原因 X"。
- 回报格式：每件一行「做了什么 / 判据在哪 / 变异结果 / 未做与原因」。
```
