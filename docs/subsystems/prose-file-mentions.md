# 正文里的文件提及

助手正文里的行内代码可以被认成文件提及，点一下打开那个文件（预览或逐行差异）。

## 1. 什么算提及（与桌面前端同一条）

只有**行内代码**是候选，且**只在围栏之外**（围栏代码块里是源码，不是链接）。

判定在 `app/lib/model/file_mentions.dart`（纯函数，唯一一处）：

- 词汇表 = **这一轮产出过的路径**（成功的 `write` / `edit` / `str_replace_editor` 调用记录下来的
  参数拼写），不是工作区文件清单 —— 桌面的 `producedFileMentions` 同样只限"这一轮产出/交付"
  （`packages/client/ui-deliverables/README.zh.md:67`）；
- 命中条件只有两条：`path === token` 或 `basename(path) === token`；
- **命中恰好一条**才成为链接；歧义（同名 basename）与未知都保持惰性；
- 只给**收口那条助手正文**（桌面要求轮次已收口且是 `tail.closing.finalNode`，
  `ui-chat/src/client/chat/AssistantNodeView.tsx:19-27`）；中间步骤与思考正文不认。

行内代码的扫描规则照 CommonMark 的 code span：开闭反引号串长度必须相等、内容换行归一成空格、
首尾各剥一层空格。围栏判据与 `ui/dsh_markdown.dart` 的 `normalizeInlineHtml` 同一套
（3 个及以上的 `` ` `` 或 `~`，最多 3 个前导空格；未闭合的围栏一直算围栏内）。

## 2. 点开之后

所有入口（正文提及、改动卡行、侧栏行、文件页）只走一个动作：
`AppModel.openFile(FileOpenRequest{path, mode, seq?, index?})`。

- `mode: preview` → `file.read`（按会话 scope 解析路径，宿主侧）；
- `mode: diff` → `file.diff`（坐标 `seq` + 下标，见 `changes-card.md` §4）。

提及点开默认是预览；右抽屉的文件面板显示内容与"返回改动"。

## 3. 路径不解释

手机把 token **原样**交给 `file.read`：不拼 cwd、不规范化分隔符 / 大小写、不判断工作区归属、
不查本地文件 —— 这些都在电脑上（`docs/subsystems/files-page.md` §2）。

## 4. 已知边界

- 只有工具调用改过的文件可点（与桌面一致）；用户随手写的其他路径仍是普通代码。
- 词表来自 `tool/call` 的参数拼写，比桌面的"成功结果 + `presented` 交付物"少一路；
  交付物那一路等 `deliverables` 投影进手机。
- 流式尾条目里不可点（还没有 "这一轮" 的条目身份）；落定后同一条消息立刻可点。
