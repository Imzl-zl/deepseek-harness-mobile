# Agent Note: 右侧「文件」面板接上真的改动清单（从工具调用推导）

Status: implemented

## Problem

右侧「文件」面板一直是**空态**：「还没有改动 / 电脑侧这一轮改了什么，会在这里
列成差异」。它不假，但没用 —— 用户问的「右侧侧滑就是文件、子智能体那几个」里，
子智能体与任务都是真的，只有文件这一页什么都没有。

## 数据从哪来（不是编的，也不需要新方法）

DSH 的 `packages/client/ui-deliverables/src/client/turn-deliverables.ts`。
它的文件头注释就把这条数据的性质写清了：

> model-free: produced paths come from successful first-party mutation calls and
> their recorded file targets, changed files from the Host's recorded git diff

**"model-free"** 是关键：路径从**成功的变更类工具调用**推导，不需要模型自述、
也不需要额外的接口 —— 而工具调用我们本来就在投影（`tool/call` 的
`{name, arguments}`）。所以手机端能算出同一份事实。

判据逐条照抄 `mutationPath`（`:61-77`）、`validEditArgs`（`:150-158`）、
`editorMutationPath`（`:90-112`）、`pathValue`（`:115-117`）：

| 工具 | 条件 |
|---|---|
| `write` | `content` 是字符串 且 `file_path` 非空白 |
| `edit` | `old_string` 非空 + `new_string` 是字符串 + **两者不同** + `replace_all` 缺省或 bool，且 `file_path` 非空白 |
| `str_replace_editor` | 按 `command`：`create` 要 `file_text`；`str_replace` 要非空 `old_str`（`new_str` 可省）；`insert` 要整数 `insert_line ≥ 0` 且 `new_str` |
| 其它 | `null` |

**`old_string == new_string` 判为不改动** —— 相同的替换不产生 diff，算进去会让
面板凭空多一行。

## 工具名大小写：查了真日志才敢定

规则里 switch 的是小写 `write` / `edit` / `str_replace_editor`。而**示例数据**里
写的是 `Write` / `Read` / `Bash` / `Grep`。谁对？

**用真日志定论**（`~/.dsh/sessions/**/session.v4.jsonl.zstd`，多帧 zstd，
取最大的 4 个）：

```
pwsh × 3547   edit × 2169   read × 1738   grep × 591   write × 460
```

**全是小写**，与 DSH 的 switch 一致。所以：规则照小写写，**示例数据那是错的**
（真线上永远不会是 `Write`），一并改成 `read` / `pwsh` / `grep` / `write`。
（`pwsh` 而不是 `bash`：这台机器上的 shell 工具就叫 `pwsh`，写 `bash` 是照搬
别处的名字。）

## Decision

1. `lib/model/changed_path.dart` —— `changedPathOf({name, argumentsJson})`
   纯函数，逐条照上表。
2. `ToolCallItem.changedPath` —— **只存路径，不存 `arguments`**：
   `write` 的参数里是**整个文件内容**，挂在条目上等于把会话里写过的每个文件
   再存一份（内存翻倍）。
3. `AppModel.changedFiles` —— 去重（同路径取**最后一次**的 `diffStat`），
   顺序按最后一次改动从新到旧。
4. 面板：`文件` 页签 = 路径；`差异` 页签 = 路径 + `+N −M`。
   **两个页签同一份真数据** —— 否则会出现"文件页列着 5 个文件、差异页说
   还没有改动"那种自相矛盾（正是 2026-10-20 修掉过的那类）。
   没有 `diffStat` 的行**不显示 `+0 −0`**（那会把"不知道"说成"没变"）。
5. 表头副标题给出现有文件数（`1 个文件`），与面板体同一真值来源。

## Alternatives considered（否掉的）

- **把 `arguments` 留在 `ToolCallItem` 上、渲染时再抽路径**：`write` 的参数是
  整个文件内容，内存翻倍。否。
- **"差异"页签先去读 `tool/result` 的 `metadata.diffs` 渲染真 diff**：
  那是下一步（要 diff 渲染器）；现在先给路径 + 行数增量，
  比空态强且**不假**。否（不是不做，是这一批不做）。
- **只认 `write`/`edit`，不管 `str_replace_editor`**：DSH 认它，少认一个就会
  有文件改动**不出现**在面板里 —— 那是"看起来没改"。否。

## Consequences

- 收益：「文件」面板从空态变成真清单；数据零新增接口（工具调用已经在手）。
- 代价：投影时多一次 `jsonDecode`（每个 `tool/call` 一次；参数通常几 KB，
  只在建立条目时跑一次）。`ToolCallItem` 多一个字段。
- 验证：
  - `changed_path_test.dart` 13 条 —— 六种参数形状、`old_string==new_string`
    不算改动、`replace_all` 类型、`insert_line` 为负、非变更类工具一律 null、
    非 JSON / 非对象一律 null。
  - **真机**：示例会话 → 右抽屉「文件」→ 表头「1 个文件」、差异页
    `lib/theme/dsh_icons.dart +100 −0`（截图确认）。
  - `flutter test 880` 全绿。
