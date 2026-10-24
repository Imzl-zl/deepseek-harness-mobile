# 下一轮提示词：`@` 提及 / 用量时间范围 / 插件启停 / 附件上限 / 计划审查卡

> 用法：新会话整段复制粘贴（或直接读这个文件）。
> **这一轮写代码**，方案与事实都已核实，不要重新论证方向；实现中发现方案不成立就**停下来回报**。
> 预期成本：**0 次模型请求、0–1 真机回合**（真机只用于最后看手感，可选）。

---

## 0. 你要接手的现状

项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，中文回复）。
`connector/`（TS，电脑侧 DSH 插件）+ `relay/`（中转）+ `app/`（Flutter）+ `protocol/` + `docs/`。
DSH 参考源码（只读）：`D:\sudy\github\deepseek-harness`，当前 **0.2.1-rc.3**。

**先读**（按顺序）：

1. `AGENTS.md` —— 铁律：宿主语义优先、不猜、**改源码只用编辑工具**、非平凡改动要决策笔记、提交前看全量 `git status`
2. `memory.md` —— 「已知缺口」「范围决定（别再当缺口）」「已知缺口」里的更正记录
3. `docs/subsystems/remote-channel.md` §5.7（方法表）、§15（已知限制）
4. `.agents/notes/implemented/2026-10-24-slash-suggestion-menu-single-source.md` —— `/` 菜单怎么做的，任务 A 照同一形状

现有门禁（全绿，别弄红）：connector **621**、flutter **1175**、boundary **369**、`dart analyze --fatal-infos` 0、`dart format` 0。

## 0.5 三个"单源"（先记死，别在实现里另立一套）

两端不是"桌面 + 简化手机"，而是**同一个输入的两种接法**：

1. **限制与数据：单源在 DSH 的投影。** 上传上限读 `imageLimits`（`packages/api/session-controller/src/list.ts:98-105`，
   值来自 `packages/attachment/attachment/src/index.ts:34-46`）；权限档读 `permissions`；用量读 `tokenUsage`。
   **手机侧不许写死自己的数字**（现在一条都没有，保持这样）。超限时原样显示 DSH 的码（`IMAGES_TOO_LARGE` /
   `TOO_MANY_IMAGES`），不翻译成自家文案（契约 §3.1 的码表）。
2. **载荷形状：单源在契约 §5.7。** `session.prompt` 只有一种形状（内容块 + `submittedAttachments`），
   手机发的和桌面发的是同一个东西。做不到的只允许叫"没接线"，不许叫"手机版少几个字段"。
3. **仲裁：单源在 gateway 的 owner-client waterfall。** 两端同时收到同一条交互，**谁先答谁赢**，
   其余端收 `cancel`（已落地 + 真机证据：`implemented/2026-10-23-interaction-as-gateway-client.md`）。

**唯一允许我们自己定的是"通道层参数"**：帧大小、分页、输入去抖（150 ms）、退避曲线 ——
它们描述的是我们这条管道，不是业务语义；写这些时不许把业务规则也塞进去。

---

## 1. 任务 A：`@文件` + `@会话`（主要活）

### 已核实的 DSH 事实（直接引用，不用重查）

- `@` 与 `/` 是**同一个输入触发器框架**：`packages/client/ui-input-trigger/src/types.ts:34`（`TriggerChar = '/' | '@'`）。
- `@` 的 token 是**普通文本**，宿主拿词表匹配：`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`
  （`TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`、`FOLDER_REF_RE`；触发符必须在**行首或空白之后**，不跨行）。
- 背后两个 Remote（**只透传，不新增能力**）：
  - `packages/api/session-controller/src/file-references.ts:32-39` → `fileReferences.list(agent, query, signal)`，
    候选只有 `{path, kind:'file'|'directory'}`（"path-only、确定性"）
  - `packages/context/session-reference/src/index.ts:88` + `@Remote('candidates')` → 会话候选，
    **直接返回拼好的 `mention` 文本**

### 要做

1. **连接器**（`connector/src/handlers.ts`）两个只读方法，形状照现有窄口：
   - `refs.files`：入参 `{sid, query}` → `{files: [{path, kind}]}`
   - `refs.sessions`：入参 `{sid, query}` → `{sessions: [{sid, title, mention}]}`
   - 走 `ctx.remote.fileReferences` / `ctx.remote.sessionReferenceResolver`（`inject` 加这两个命名空间）；
     入参校验用现有错误码；**候选上限交给宿主**（它有 `candidateLimit`），我们不再截断；
     **空结果就是空数组**；宿主抛错原样过线。
2. **能力位**：`repo.info.caps.references`（两个 handler 都挂上才 true）—— 老连接器没有它，手机**不显示** `@` 面板。
3. **手机**（`app/lib/ui/dsh_composer.dart` + `app/lib/data/app_model.dart`）：复用 `/` 那条 suggestion 缝，
   加触发符 `@`；**触发判据与宿主一致**；输入去抖 **150 ms**，新按键取消在飞请求，**不缓存不预取**；
   选中后**只插入纯文本**：目录 `@path/`、文件 `@path`、会话用宿主给的 `mention` 原样；
   面板三态：空态 / 失败态（显示 `lastError`，**不是空列表**）/ 列表态。
4. **判据**：connector 两个方法各 2 条（有候选 / 空候选）+ 宿主抛错原样 1 条 + caps 有无各 1 条；
   flutter 触发判据 3 条 + 插入文本 2 条 + 失败态 1 条 + 老连接器不显示面板 1 条；
   改完做**一次变异校验**（改坏触发判据或 caps 判断，确认恰好变红）再还原。

## 2. 任务 B：用量页时间范围（小活，先证明"不改契约"）

- 事实：`usage.summary.byDay` 已带全部保留日期的 `{date, turns, tokens}`（契约 §5.7 规则⑤）。
- 要做：`app/lib/ui/usage_page.dart` 的热力图卡片加 **7 / 30 / 90 / 全部** 切换，**纯前端切片**；
  切 7/30 天时热力图仍是连续日历（不是只画 7 格），只是取最近 N 天的窗口。
- **不要**改 `usage.summary` 出入参（若发现 byDay 覆盖不够，停下来回报，别自己加参数）。
- 判据：切片窗口 2 条（含"全部"）+ 切换后读数仍正确 1 条。

## 3. 任务 C：插件页（清单 + 启停）

- 已核实：`packages/host/plugin-inventory/src/index.ts:70` 只有 `list()`（只读快照，**不是**方法面）；
  **真正的方法面在 `packages/boot/plugin-manager/src/index.ts`，14 个 `@Remote`**，本任务只用三个：
  `listPlugins:439`、`setPluginEnabled:796`、`setBundleEnabled:814`。
- 做法照任务 A：`plugin.list` → `{plugins: [...]}`（字段以 `PluginInfo` 为准，**不翻译**）、
  `plugin.setEnabled` → `{name, enabled}`；`repo.info.caps.plugins` 做能力位。
- **安装 / 卸载 / 升级不做**（`installBundle:835` / `removeBundle:999` / `updateBundle:677`，风险面另议）。
- 判据：清单 2 条（有插件 / 空）、启停各 1 条（成功 / 宿主抛错原样）、caps 2 条；界面为只读列表 + 开关。

## 4. 任务 D：附件上限（用宿主的数，不发明）

- 默认值（`packages/attachment/attachment/src/index.ts:34-46`）：`maxImageBytes` **50 MB**、
  `maxImagesPerMessage` **20**、`maxMessageImageBytes` **200 MB**、`maxImagePixels` 64,000,000、
  `maxImageDimension` 65,535、`mediaTypes` = png/jpeg/webp/gif（可配）。
- 暴露方式：`packages/api/session-controller/src/list.ts:98-105` 把 `ctx.attachments.imageLimits`
  注册成投影 **`imageLimits`** ⇒ 我们已在调 `session.projections`，**不用加方法**。
- 现状：`app/` 与 `connector/` 里一条限制都没有（grep 不到 `maxBytes`/`IMAGES_TOO_LARGE`），全靠 DSH 拒绝。
- 要做：从 `session.projections` 读 `imageLimits`，选图时用这些数前置校验，超限文案说清是哪一条；
  并把 DSH 的拒绝码原样呈现。**禁止写死数字。**
- 判据：超数量 / 超单图 / 超总量各 1 条（用假上限喂进去）+ "投影缺席（老连接器）⇒ 不前置拦，靠拒绝码" 1 条。

## 5. 任务 E：计划审查卡 = **卡来自请求**（C11 已改判"可做"）

- 事实：`plan-mode` 的 `exit_plan_mode` 调 `userQuestions.ask()`（`packages/plan/plan-mode/src/index.ts:316-333`），
  与 `ask_user_question` **同一条 waterfall**（`packages/api/remotes/src/remote-events.ts:28,54` 的 allowlist 就这两个事件）。
- 请求里带齐渲染所需：`questions[0]` 的 `header` / `question` / `detail`（整份计划 markdown）/ `options`，
  外加 `intent: { kind: 'plan-review', approve, callId }`。
- 手机端**已有落地形态**：`TakeoverController` 浮动卡按 `InteractionKind` 渲染，
  `InteractionKind.plan` 分支齐全（`app/lib/ui/takeover.dart:219,533-535,613-615`，标题「等待确认计划」），
  **不依赖投影锚点**。
- 卡点：`connector/src/dsh/interaction-client.ts:424-430` 主动选了"不认它"，理由是"手机上没有那张卡"——现在不成立。
- 要做：
  1. 连接器：提问 waterfall 若认不出 `tool/call`，就**直接从请求造 item**（`questions` 原样 + `detail`）；
     身份优先 `intent.callId`、其次 `wait.callId`（只用于幂等键与去重），两者都没有才照旧委托。
  2. 手机：plan 卡把 `detail` 展示出来（可折叠/滚动），答「批准」/「继续规划」，走既有 `interaction.respond`。
- 判据：connector 3 条（plan-review 造卡 / 身份回退 / 无身份仍委托）；app 2 条（渲染 detail、答复载荷）。

## 6. 任务 F（可选，最后）：文件预览

`packages/api/workspace-files/src/index.ts` 有 `read` / `readBytes` / `stat` / `list`（还有流式 `changes`）。
文本与图片预览不用改 DSH；但入参是 `WorkspaceFileScope`（要 workspace 身份），比 `fileReferences` 重 ——
**只给"文件页/预览"用，不要用在 `@` 补全里**。

## 7. 版本基线（**已完成**，别再动）

`connector` 的 peer/dev 已对齐宿主实际安装的 **`0.2.1-rc.3` + `cordis 4.0.5`**（`schemastery 3.18.5` 本来就对），
`pnpm install`（本地 store，8.7 s）→ `tsc --noEmit` 0 → `build` 过 → `pnpm test` **621/621**。
取舍与"以后每次 DSH 升级怎么量"见 `implemented/2026-10-24-dsh-version-baseline-rc3.md`。

## 8. 硬规则（违反即返工）

- 不新增宿主没有的语义：不加超时、不加本地缓存、不做文件树索引、不在手机侧解析路径归属。
- 不许猜：引用 DSH 行为给 `packages/...:行号`；查不到写「未找到」。
- 改源码**只用编辑工具**（`edit`/`write`），不许 shell 字符串替换；提交前看完整 `git status`（防意外空文件）。
- 契约 §5.7、`docs/`、`memory.md`（门禁数）、`tools.md`（项数）**同批改**，四处一致。
- 真机不是必须：这一轮以测试为准，手感留到下一轮。

## 9. 交付

- 每个任务一个提交 + 一篇 `implemented/<日期>-<slug>.md`（含 Alternatives considered 与代价）：
  A `...-file-and-session-mentions.md`、B `...-usage-range-client-slice.md`、
  C `...-plugin-list-and-toggle.md`、D `...-attachment-limits-from-dsh.md`、E `...-plan-review-card-from-request.md`
- 门禁全绿：
  ```powershell
  cd connector; pnpm exec tsc --noEmit; pnpm build; pnpm test
  cd ..\app; dart format --output=none --set-exit-if-changed .; dart analyze --fatal-infos lib test integration_test; flutter test
  cd ..; node app/tools/verify-platform-boundary.mjs
  ```
- `git push origin main`。

## 10. 明确不做（别花时间）

- 插件的**安装 / 卸载 / 升级**：有 Remote 但风险面大，先不做。
- **后台送达 / 厂商推送**：MIUI 实测已定案（`docs/subsystems/notifications.md` §2.1/§2.2、契约 §15）。
- 设置 42 项对账：**可选只读核对**，不改代码；有结论就写进 `docs/settings-porting-notes.md`。

## 11. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
git log --oneline -3
Select-String -Path connector\src\handlers.ts -Pattern "handlers\['session.projections'\]" -Context 0,18   # 透传写法
Select-String -Path app\lib\ui\dsh_composer.dart -Pattern 'slashQueryOf|_SlashSuggestions' -Context 0,6    # / 的缝
node app/tools/flutter-api.mjs <符号>                                                                     # Flutter 行为查证
```
