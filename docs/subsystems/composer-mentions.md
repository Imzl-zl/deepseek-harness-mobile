# 输入栏的 `@` 候选

现状事实。因果取舍见
`.agents/notes/implemented/2026-10-24-file-and-session-mentions.md`，方法表见
`remote-channel.md` §5.7 的 `refs.files` / `refs.sessions`。

## 1. 它是什么

`@` 与 `/` 是同一个输入触发器框架的两半（DSH
`packages/client/ui-input-trigger/src/types.ts:34` 的 `TriggerChar = '/' | '@'`）。
`@` 的 token 是**普通文本**：宿主按 `TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`
与 `FOLDER_REF_RE` 扫草稿（`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`），
触发符必须在**草稿开头或空白之后**，名字段不含空白、不跨行。

手机上它是输入框上方的一行候选（与 `/` 同一条缝），内容来自电脑侧两个只读方法：

| 候选 | 来源 | 当选后插进输入框的文本 |
|---|---|---|
| 文件 | `refs.files`（宿主的 `fileReferences.list`） | `@path` |
| 目录 | 同上（`kind: 'directory'`） | `@path/`（补一个斜杠，与宿主的目录 token 同形） |
| 会话 | `refs.sessions`（宿主的 `sessionReferenceResolver` 的 `@Remote('candidates')`） | 宿主给的 `mention` **原样**：`@[标题](dsh-session:<base64url>)` |

## 2. 触发判据（`app/lib/model/mention.dart` 的 `atTriggerOf`）

三条，与宿主逐条对齐：

1. `@` 在**草稿开头或空白之后**（`x@name` 永不匹配）；
2. token 里**没有空白**（于是也不跨行）—— `@src ` 之后就不再是 token；
3. 取**最后一个** `@`（正在打的那个）。

正文中间的 `@`、邮箱地址里的 `@`、跨行的 `@` 都不出面板。

## 3. 面板三态

| 态 | 判据 | 显示 |
|---|---|---|
| 列表 | 两半里至少有一条 | 每行一枚胶囊（文件在前、会话在后，顺序就是电脑侧给的顺序） |
| 空 | 电脑侧回空数组 | 「没有匹配的文件或会话」 |
| 失败 | 这次没查成（原因在 `ProtocolException.message`） | **电脑侧的原话**（截两行） |

**两种"没有"不是一回事**：空列表是电脑侧的答案，失败是这条链路没走通。
把失败画成空列表，用户会以为自己路径打错了。

## 4. 通道层参数（我们自己的三个数，理由都不是业务语义）

- **输入去抖 150 ms**：连续打字只落到最后一次查询；去抖是"我们这条管道打一个来回的节奏"。
- **新按键作废在飞答复**：通道没有"取消这次请求"的语义（契约 §10 没有取消），所以"取消" =
  换一个代号，回来的旧答复对不上就丢掉 —— 它不会盖住新的结果。
- **不缓存、不预取**：候选随工作目录与所打的字变化，存一份就是第二个真值源。

## 5. 能力位

`repo.info.caps.references`（连接器侧 `referencesAvailable(ctx)`：`fileReferences` /
`sessionReferenceResolver` / `agents` 三键俱在才 true，**与挂不挂两个方法读同一个函数**）。

老连接器不报这个键 ⇒ 手机 `mentionsAvailable=false` ⇒ 面板整块不出现，
且**一个请求都不发**。这是诚实的空态，不是"这台电脑没有文件"。

## 6. 已知边界

- 会话候选的 `mention` 里装着 DSH 会话 id 的 base64url —— 宿主的引用语法，
  它是 §5.1"手机只见 `sid`"的**有意例外**（契约 §5.7 那一行已写明）。
- 候选**不排序、不截断**：顺序与条数都是宿主的答案（上限 `candidateLimit` 由部署配）。
- 目录候选插进去以后**面板仍然跟着你往里打字**（`@src/` 之后继续打就是新的查询）；
  文件候选插入后不再弹，直到你改动那一段 token。
- 失败文案是电脑侧原话，可能很长（截两行、不可展开）。
