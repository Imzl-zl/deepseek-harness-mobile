# Agent Note: 每步视图只做三个高频，其余明确不做

Status: implemented

## Problem

用户原话：「web端的每一步查看子智能体、编辑、读取、运行命令，等等都有显示，APP 显示全不全？」

改造前手机只有一个通用卡：工具名 + 一行参数 + **纯文本结果**。而 DSH 按
`tool.call.toolview` 注册了 9 个专用视图（bash→TerminalBlock、read→ReadBlock、
edit|write→DiffBlock、grep|glob→SearchBlock、web_*→WebBlock、todo_write、ask_user_question、
subagent 等→ToolDetails、其余→通用 IN/OUT）。

## Decision

只做**三个高频**（命令 / 读 / 改），其余保持通用卡并在文档写明**有意偏离**：

1. `app/lib/model/tool_view.dart` —— 从 `tool/result` 的 `data.meta` 解析出三个变体
   （`BashResultView` / `ReadResultView` / `DiffResultView`），落到 `ToolCallItem.view`。
   形状逐个读过 DSH 源码（`read.ts:124-132`、`edit.ts:113-117`、`write.ts:103-110`），
   并用**真机落盘的那一帧**（`test/fixtures/real-session-events.json`）当判据。
2. `app/lib/model/diff.dart` —— `{oldText,newText}` → `DiffLine`：先剥公共前后缀，
   再在 ≤400 行的中间段跑 LCS，超限就整段替换（如实降级）。
3. `app/lib/ui/tool_views.dart` —— 三张卡：
   命令行（输出 + stderr 段 + `exit N`/`signal`/`[timed out]` 胶囊）、
   读文件（路径 + `共 N 行` + 行号两列）、改文件（`+N −M` + 内联 diff）。

**顺带修掉一个生产 bug**：`diffStatOf` 原来从 `message.metadata.diffs` 读 hunk，
而真日志里它在 `data.meta.diffs` —— 于是 `+N −M` 在真机上从来没出现过。

## Alternatives considered

1. **把 DSH 的 9 个视图全做**
   - 最强理由："对齐"最省心的判据就是视图数一样；`SearchBlock` / `WebBlock` 也都不难。
   - 为何被否：每张卡都要自己的解析分支、渲染规格与判据，而 `grep`/`web`/`todo` 在手机
     会话里出现频率远低于读/改/跑。三个先用起来，其余等有真实需求再做 ——
     但必须**写进文档**，否则下一轮会把"没做"当成"已经对齐"。
2. **继续用通用卡，只把 `detail` 排版弄好**
   - 最强理由：零解析、零风险，改一行样式就"看起来像样"。
   - 为何被否：用户要的正是"每一步能看出来是什么"——`read` 没有行号就没法对着说
     "第 12 行那里"；`edit` 没有 diff 就只能看到一句"已修改"。这是能力差，不是样式差。
3. **`edit` 只显示 `+N −M`，不画 diff 正文**
   - 最强理由：`diffs` 的 hunk 是整段前后文本，画 diff 要自己写行级算法。
   - 为何被否：用户举的例子就是"编辑…都有显示"，而 Web 的 DiffBlock 是**内联 diff**。
     只给数字等于把"改了什么"藏起来。行级算法 120 行，代价可控。
4. **把 `DiffLine`/`DiffKind` 下移到 `model/` 再动手**
   - 最强理由：数据在 model、画在 ui 才对称；现在是 `model/diff.dart` 依赖
     `ui/dsh_diff.dart` 的类型。
   - 为何被否（本轮）：那是纯搬家 + 改所有引用点，和"做三张卡"混在一个提交里会让 diff
     难审。已写进 `docs/subsystems/tool-views.md` §3 的已知缺口，作为独立整理项。

## Consequences

- 收益：读/改/跑三步在手机上能看清"跑的是什么、出没出错、改了哪几行"；
  顺带修好了 `+N −M`（真机上第一次出现）。
- 代价：
  - `read` 的**点开到行**（DSH 的 `read-row.tsx:14-20` 能跳到文件对应行）没做 ——
    手机上还没有"文件查看器"这个面，做了也跳不过去。
  - 一个 hunk 最多画 160 行、一次读最多画 200 行，超出说"还有 N 行未显示"
    （长文件不把页面撑长）。
  - LCS 只在 ≤400×400 的中间段跑；更大的对比整段替换 —— **如实降级，不猜配对**。
  - 图片结果仍不渲染（要 `session/attachment` 面）。
- 单测 `app/test/tool_views_test.dart` 14 条；**变异校验**：把
  `diffStatOfTexts` 换回"按两段文本行数"⇒ 两条断言当场红（`+1` 找不到）。
- 真机证据（`d61cf622`，`shots-2026-10-22/`）：
  `b2-bash-card.png`（`done` + `exit 0` 胶囊）、
  `b6-read-block.png`（路径 + `共 3 行` + `1 alpha / 2 beta / 3 gamma`）、
  `b7-edit-block.png`（`+1 −1` + 红 `− beta` / 绿 `+ BETA` 的内联 diff）。
