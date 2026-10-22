# 每步视图（bash / read / edit|write）

三个高频工具各有一张**专用卡**；其余工具继续走通用 IN/OUT 文本（见 §3 的"有意偏离"）。

## 1. 数据来自哪里

`tool/result` 的 `data.meta`（DSH 的 `presentationMeta`）与收口文本里的状态标记。
真机落盘的一帧（`app/test/fixtures/real-session-events.json`）：

```json
{"type":"tool/result","seq":71,"data":{
  "message":{"role":"tool","content":[{"type":"text","text":"<path>…</path>…"}]},
  "meta":{"path":"…memory.md","offset":1,"lines":[{"number":1,"text":"# …"}],"totalLines":149}}}
```

| 工具 | meta 形状 | 出处 |
|---|---|---|
| `read` | `{path, offset, lines:[{number,text}], totalLines, lang?}` | `packages/fs/tool-fs/src/read.ts:124-132` |
| `edit` | `{path, diffs:[{path, oldText, newText}]}` | `packages/fs/tool-fs/src/edit.ts:113-117` |
| `write` | `{operation, path, diffs:[…]}` | `packages/fs/tool-fs/src/write.ts:103-110` |
| `bash` / `pwsh` | 只有 `{cwd}` —— **状态在文本末尾**：`[exit code: N]` / `[killed by signal: X]` / `[timed out …]` / `[stopped: …]` | `packages/shell/tool-bash/src/render.ts:52-61`；客户端解析先例 `ui-tool/src/client/tool/models/terminal-card-model.ts:293-299` |

解析在 `app/lib/model/tool_view.dart`（纯函数，`ToolResultView` 三个变体），
落到 `ToolCallItem.view`；渲染在 `app/lib/ui/tool_views.dart`。

## 2. 三张卡长什么样

| 卡 | 内容 |
|---|---|
| 命令行 | 输出正文 + `[stderr]` 段（错误色）+ 底部 `exit N` / `signal X` / `[timed out …]` 胶囊（0 绿、非 0 与被杀红）。**没有标记按 exit 0**（DSH 同一条） |
| 读文件 | 路径行（右端 `共 N 行`）+ `行号 + 文本` 两列；超过 200 行说"还有 N 行未显示" |
| 改文件 | 路径行（`write` 带"新建/更新"）+ `+N −M` + 每个 hunk 一段内联 diff（`DshDiff`，行号双列、`−` 红 `+` 绿） |

`+N −M` **按折出来的 diff 行数算**（`{a,b}`→`{a,c}` 是 `+1 −1`）。
顺带修掉一个生产 bug：旧代码从 `message.metadata.diffs` 读 hunk，
而真日志里它在 `data.meta.diffs` —— 于是 +N/−M 在真机上**从来没出现过**。

## 3. 有意偏离：其余工具不专门做

`grep`/`glob`（SearchBlock）、`web_*`（WebBlock）、`todo_write`（todo diff）、
`ask_user_question`（AskQuestionCard）、`subagent` 等（ToolDetails 字段表）在 DSH 里
各有专用视图，手机这一版**不做**，继续走通用卡（工具名 + 参数摘要 + 结果原文）。
理由：这三张是会话里出现频率最高的（读/改/跑），其余多数在手机上一天见不到几次；
而每做一张都要自己的解析分支与渲染规格，收益递减。**下一轮别以为已经对齐**。

另外两处已知缺口：
- **图片结果不渲染**（`attachmentCount` 只数不画，读附件要 `session/attachment` 面，尚未接）；
- `DiffLine` / `DiffKind` 这两个类型还住在 `ui/dsh_diff.dart`，而 `model/diff.dart`
  依赖它们（数据在 model、画在 ui 才对）。把类型下移是一件独立的整理，没混在这一轮做。

## 4. 判据

- 单测 `app/test/tool_views_test.dart`（14 条）：`read` 用**真日志那一帧**解析；
  `bash` 的五种收口（正常 / 非零 / stderr / 被杀 / 超时）；`edit|write` 的 `+N −M`
  是 diff 行数而非文本行数；diff 的前后缀剥离与行号；三张卡的渲染。
  **变异校验**：把 `diffStatOfTexts` 换回"按文本行数"⇒ 两条断言当场红（`+1` 找不到）。
- 真机（`d61cf622`，`shots-2026-10-22/`）：`b2-bash-card.png`（`done` + `exit 0`）、
  `b6-read-block.png`（路径 + 共 3 行 + 行号）、`b7-edit-block.png`
  （`+1 −1` + 红 `− beta` / 绿 `+ BETA` 的内联 diff）。
