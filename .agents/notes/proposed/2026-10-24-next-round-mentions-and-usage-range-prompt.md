# 下一轮提示词：`@` 提及（文件 / 会话）+ 用量页时间范围

> 用法：新会话整段复制。**这一轮写代码**，方案已经定了，不要重新论证方向，只允许在实现中发现方案不成立时回报。
> 预期成本：**0 次模型请求、0–1 真机回合**（真机只用于最后看一眼面板手感，可选）。

---

## 0. 你要接手的现状

项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，中文回复）。连接器 `connector/`（TS，电脑侧插件）
+ `relay/` + `app/`（Flutter）+ `protocol/` + `docs/`。

**先读**（按顺序，别跳）：

1. `AGENTS.md` —— 铁律：宿主语义优先、不猜、**改源码只用编辑工具**、非平凡改动要决策笔记、提交前看全量 `git status`
2. `memory.md` —— 「已知缺口」「范围决定」
3. `docs/subsystems/remote-channel.md` §5.7（方法表）—— 你要加的两行就写在它旁边
4. `.agents/notes/implemented/2026-10-24-slash-suggestion-menu-single-source.md` —— `/` 菜单怎么做的，**本轮照同一形状做 `@`**

现有门禁（全绿，别弄红）：connector **621**、flutter **1175**、boundary **369**、`dart analyze --fatal-infos` 0、`dart format` 0。

## 1. 任务 A：`@文件` + `@会话`（主要活）

### 已定的方案（不要重新设计）

DSH 原生事实（已查证，直接引用即可）：

- `@` 与 `/` 是**同一个输入触发器框架**：`packages/client/ui-input-trigger/src/types.ts:34`（`TriggerChar = '/' | '@'`）。
- `@` 的 token 是**普通文本**，宿主拿词表匹配：`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`
  （`TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`、`FOLDER_REF_RE`；触发符必须在**行首或空白之后**）。
- 背后两个 Remote（**我们只透传，不新增能力**）：
  - `packages/api/session-controller/src/file-references.ts:32-39` → `fileReferences.list(agent, query, signal)`，
    候选只有 `{path, kind:'file'|'directory'}`（"path-only、确定性"）
  - `packages/context/session-reference/src/index.ts:88` + `@Remote('candidates')` → 会话候选，
    **直接返回拼好的 `mention` 文本**（`formatSessionReferenceMention(...)`）

### 要做的事

1. **连接器**（`connector/src/handlers.ts`）加两个只读方法，形状照现有的窄口风格：
   - `refs.files`：入参 `{sid, query}`，返回 `{files: [{path, kind}]}`
   - `refs.sessions`：入参 `{sid, query}`，返回 `{sessions: [{sid, title, mention}]}`
   - 通过 `ctx.remote.fileReferences` / `ctx.remote.sessionReferenceResolver` 透传（照 `session.projections` 的取法）；
     `inject` 里加这两个命名空间；**入参校验**照现有 handler（缺 `sid`/`query` 直接回 `connector/invalid-params` 之类现有码）。
   - **候选项上限交给宿主**（它自己有 `candidateLimit`）；我们不再加一层截断。
   - **空结果就是空数组，不是错误**；宿主抛错原样过线（不改码、不吞）。
2. **能力位**：`repo.info.caps` 加 `references: boolean`（只有两个 handler 都挂上才 true）——
   老连接器没有它，手机就**不显示 `@` 面板**（与 `/` 的白名单同一条纪律：不猜、不降级造假数据）。
3. **手机**（`app/lib/ui/dsh_composer.dart` + `app/lib/data/app_model.dart`）：
   - 复用 `/` 那条 suggestion 缝，加第二个触发符 `@`；**触发判据与宿主一致**（行首或空白之后，不跨行）。
   - 输入去抖 **150 ms**；新按键取消在飞的请求（同一个取消机制，别加缓存、别预取）。
   - 选中后**只插入纯文本**：目录 → `@path/`（宿主语义：目录让补全继续，文件收尾）；文件 → `@path`；
     会话 → **原样插入宿主给的 `mention`**。
   - 面板要有三种态：空态（"没有匹配的文件 / 会话"）、失败态（显示 `lastError`，**不是空列表**）、列表态。
4. **判据（必须写）**：
   - connector：两个方法各 2 条（有候选 / 空候选），外加"宿主抛错原样过线"1 条；`caps.references` 的有无各 1 条。
   - flutter：触发判据（行首/空白后/不跨行）3 条、选中插入文本 2 条（目录带 `/`、会话用 `mention`）、
     失败态 1 条、老连接器（无 caps）不显示面板 1 条。
   - 改完跑一次**变异校验**（把触发判据或 caps 判断改坏，确认恰好变红），然后还原。

## 2. 任务 B：用量页时间范围（小活，先证明"不改契约"）

- 事实：`usage.summary.byDay` 已带全部保留日期的 `{date, turns, tokens}`（契约 §5.7 规则⑤）。
- 要做：`app/lib/ui/usage_page.dart` 的热力图卡片加 **7 / 30 / 90 / 全部** 切换，**纯前端切片**；
  切 7/30 天时热力图仍是连续日历（不是只画 7 格），只是取最近 N 天的窗口。
- **不要**改 `usage.summary` 的入参（除非你发现 byDay 覆盖范围不足以支撑这个口径，那就停下来回报，别自己加参数）。
- 判据：切片窗口 2 条（含"全部"）、切换后读数仍正确 1 条。

## 3. 硬规则（违反即返工）

- **不新增宿主没有的语义**：不加超时、不加本地缓存、不做"文件树索引"、不在手机侧解析路径归属。
- **不许猜**：引用 DSH 行为给 `packages/...:行号`；查不到写「未找到」。
- **改源码只用编辑工具**（`edit`/`write`），不许 shell 字符串替换；提交前看完整 `git status`（防意外空文件）。
- 契约、`docs/`、`memory.md`、`tools.md` 的计数与描述**同批改**（现在四处都要一致：契约 §5.7 两行 + `caps` 说明、
  `docs/subsystems/` 里新增或更新一篇、`memory.md` 门禁数、`tools.md` 项数）。
- 真机不是必须：`@` 面板的手感留到下一轮真机看；这一轮以测试为准。

## 4. 交付

1. 一到两个提交（任务 A 一个、任务 B 一个），每个都带决策笔记 `implemented/<日期>-<slug>.md`：
   - A：`...-file-and-session-mentions.md` —— 为什么是"透传 + 插文本"、被否方案（手机侧解析 / 结构化引用）、
     token 规则引用的行号、代价（往返与去抖）
   - B：`...-usage-range-client-slice.md` —— 为什么不改契约（byDay 覆盖范围）
2. 门禁全绿：`cd connector; pnpm exec tsc --noEmit && pnpm build && pnpm test`、
   `cd app; dart format --output=none --set-exit-if-changed . && dart analyze --fatal-infos lib test integration_test && flutter test`、
   `node app/tools/verify-platform-boundary.mjs`
3. `git push origin main`。

## 5. 明确不做（别花时间）

- 插件的启停/安装日志：DSH **没有 Remote**（`packages/host/plugin-inventory/src/index.ts:70` 只有 `list`），memory 已更正。
- 计划审查卡、后台送达、厂商推送：都已定案不做（`memory.md`「范围决定」、`docs/subsystems/notifications.md` §2.1/§2.2）。
- 设置 42 项对账：**可选**，只做只读核对，不改代码；有结论就写进 `docs/settings-porting-notes.md`。

## 6. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
git log --oneline -3
Select-String -Path connector\src\handlers.ts -Pattern "handlers\['session.projections'\]" -Context 0,18   # 透传的写法
Select-String -Path app\lib\ui\dsh_composer.dart -Pattern 'slashQueryOf|_SlashSuggestions' -Context 0,6   # / 的缝
```

DSH 参考源码只读：`D:\sudy\github\deepseek-harness`。Flutter 行为查证：`node app/tools/flutter-api.mjs <符号>`。
