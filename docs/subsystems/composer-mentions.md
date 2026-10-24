# 输入栏的候选面板（`@` / `/`）

现状事实。因果取舍见
`.agents/notes/implemented/2026-10-24-file-and-session-mentions.md`、
`2026-10-25-composer-panel-rows-drill-crumbs.md`、
`2026-10-25-command-descriptions-from-host.md`、
`2026-10-25-bottom-budget-and-takeover-card.md`；方法表见
`remote-channel.md` §5.7 的 `refs.files` / `refs.sessions` / `repo.info`。

## 1. 它是什么

`@` 与 `/` 是同一个输入触发器框架的两半（DSH
`packages/client/ui-input-trigger/src/types.ts:34` 的 `TriggerChar = '/' | '@'`）。
`@` 的 token 是**普通文本**：宿主按 `TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`
与 `FOLDER_REF_RE` 扫草稿（`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`），
触发符必须在**草稿开头或空白之后**，名字段不含空白、不跨行。

手机上它是输入卡上方的一个列表，内容来自电脑侧三个只读来源：

| 候选 | 来源 | 当选后插进输入框的文本 |
|---|---|---|
| 文件 | `refs.files`（宿主的 `fileReferences.list`） | `@path` |
| 目录 | 同上（`kind: 'directory'`） | `@path/`（补一个斜杠，与宿主的目录 token 同形） |
| 会话 | `refs.sessions`（宿主的 `sessionReferenceResolver` 的 `@Remote('candidates')`） | 宿主给的 `mention` **原样**：`@[标题](dsh-session:<base64url>)` |
| 命令（`/`） | `repo.info.commands`（白名单 + 宿主的 `description`） | `/名字 `（带尾空格） |

## 2. 触发判据（`app/lib/model/mention.dart` 的 `atTriggerOf`）

三条，与宿主逐条对齐：

1. `@` 在**草稿开头或空白之后**（`x@name` 永不匹配）；
2. token 里**没有空白**（于是也不跨行）—— `@src ` 之后就不再是 token；
3. 取**最后一个** `@`（正在打的那个）。

正文中间的 `@`、邮箱地址里的 `@`、跨行的 `@` 都不出面板。`/` 的判据是
`slashQueryOf`：整段文本以 `/` 开头且**还没有空白**（有空白 = 命令名打完了）。

## 3. 面板的形状（照宿主 `MenuView`）

宿主侧唯一真值是 `packages/client/ui-input-trigger/src/client/MenuView.tsx` +
`MenuView.module.css`：

| 部分 | 规格（出处） |
|---|---|
| 位置 | 浮在**输入卡上方**、**与卡同宽**（`.menu`：`bottom:calc(100% + 4px); left:0; right:0`，`:1-8`） |
| 容器 | 浮层：`padding:4px`、`radius lg`、`elevation-prominent`（`:23-28`；`--dsw-elevation-prominent` 见 `ui-theme` 的 `gradient-shadow-text.css`） |
| 分组标题 | 11px / 500 / `label-tertiary`、`min-height:23`、`padding:5px 8px 2px`（`.sectionTitle`，`:74-86`） |
| 一行 | `min-height:34`、`padding:6px 8px`、`gap:6`、`radius md`、字号 13（`.item`，`:51-66`） |
| 行内顺序 | 图标 14 → 名字 → 右侧说明 → 目录行末尾的 chevron（`MenuView.tsx:179-212`） |
| 名字列 | ≤ 40%，超出省略号（`.itemName`，`:103-109`） |
| 说明列 | 右对齐、12px、`label-tertiary`、省略号（`.itemDescription`，`:126-136`） |
| pending | 两行骨架（32% / 48% 宽，`MenuView.tsx:147-153`） |

**分组**用宿主 zh 词典的原话，不另起中文：

- `@`：`文件与文件夹` / `对话`（`ui-reference/src/client/locales.ts` 的 `section.files` /
  `section.sessions`；`@` 的 source 是 `showGroupTitle:false`，分组来自每行的 `section`，
  `ui-reference/src/client/index.ts:258,288`）；
- `/`：`指令`（`ui-input-trigger/src/client/locales.ts` 的 `command`）。

**行内图标三档**与宿主的三种 artwork 逐字对应（`ui-primitives/src/ReferenceIcon.tsx:25-30`）：
目录 = `FolderCloseArtwork` → `folderClose`；文件 = `BrowseOutlineArtwork` → `browse`；
会话 = `ChatLinesOutlineArtwork` → `queue`（那份 artwork 的注释原话是
"matches the `queue-outline` product glyph"，`ui-primitives/src/icons/shared-artwork.tsx:13-19`）。
`/` 的行**没有图标**：宿主的图标来自客户端内置的"命令脸"
（`ui-commands/src/client/presentation.ts:54-62`），手机没有那张表，凭空配一枚就是编数据。

**pending 骨架是一次性淡入**，不做宿主的 2s 呼吸：等待通常只活一个往返（150 ms 去抖 +
一次请求），而无限动画会让 `pumpAndSettle` 的用例永远等不到静止。

## 4. drill 与面包屑

目录行**两个动作**（宿主 `ui-reference/src/client/index.ts:131-149`）：

| 动作 | 触发 | 结果 |
|---|---|---|
| 落定 | 点**行体** | 插入 `@path/` 并**关面板** |
| drill | 点**行尾 chevron** / 面包屑 | 同样插入 `@path/`，但**面板不关**，接着按新查询列子项（宿主 `{text: mention, continue: true}`） |

drill 的 **chevron 触达区是 30×22**（桌面 `.drill` 是 18×18 的方块）：高度不超过行高减去
上下 padding 的内容区，所以行高仍是 34；点偏一点落在行体上，结果是"把这个目录整个插进去
并关面板"，可撤销、不丢输入。

**面包屑只在 drill 之后出现**（`crumbsFor` 的第一条：`if (!drilled) return undefined`，
`:199-226`）。理由原话：手打的路径自带上下文（就在草稿里），而 drill 把用户正在读的文本
换成了更深的一段，欠他一条回去的路。所以判据是"这一屏是**钻进来的**"（`drilled`），
不是"查询串里有 `/`"：手打 `@src/` 不出面包屑。

形状：`工作区` → 各段 → 最后一段（`current`，不可点）。点某一段就把该层的目录 mention
写回输入框（根 = `@`）。查询串里没有 `/` 时面包屑自己消失（还在根层挑东西，没有"上一层"）。
`drilled` 在面板关掉时清空，打字不清（`InputTriggerCrumb` / `HeaderRequest.drilled`，
`ui-input-trigger/src/types.ts:79-101`）。

## 5. 高度：底部预算只有一个出处

面板上限**不是屏幕的一个比例**，而是"输入卡上方真正剩下的空间"，由
`app/lib/ui/chat_page.dart` 的 `_BottomBudget` 算一次：

```text
blockMax = 页面可见高度 − kMinConversationVisible(72)        // 会话至少露出来的高度
panelMax = min(400, blockMax − 输入栏固定件 − 统计条 − (接管卡在场 ? 它的两行 : 0))
```

- `400` 是宿主的**设计上限**（`MenuView.tsx:28` 的 `MAX_HEIGHT`）；桌面那个
  `TOP_MARGIN = 84`（会话头部 76 + 8，`:35`）**不搬** —— 那是桌面头部的尺寸。
- 同一个 `blockMax` 也是底部那一块（接管卡 + 队列条 + 输入栏 + 统计条）的硬上限；
  接管卡在里面拿 `Flexible` 的剩余空间。于是"卡片 + 面板"不可能相加超过可用高度。
- 三个常量都是**上界**，各有一条棘轮用例守着：输入栏固定件与统计条在
  `app/test/composer_layout_test.dart`、接管卡两行在 `app/test/takeover_test.dart`。
- 面板**自己滚**（`SingleChildScrollView`），不把输入栏那一列撑开。

## 6. 三态

| 态 | 判据 | 显示 |
|---|---|---|
| 列表 / pending | 还没答复 / 至少有一条 | 列表；pending 时给两行骨架 |
| 空 | 电脑侧回空数组 | 「没有匹配的文件或会话」一句话 |
| 失败 | 这次没查成（原因在 `ProtocolException.message`） | **电脑侧的原话**（截两行） |

**两种"没有"不是一回事**：空列表是电脑侧的答案，失败是这条链路没走通。
把失败画成空列表，用户会以为自己路径打错了。空与失败都**不占列表**（宿主的错误是 toast）。

## 7. 通道层参数（我们自己的数，理由都不是业务语义）

- **输入去抖 150 ms**：连续打字只落到最后一次查询；去抖是"我们这条管道打一个来回的节奏"。
- **drill / 面包屑不走去抖**：它们由一次点击产生（不是打字），等 150 ms 只让"进去了"慢半拍。
- **新按键作废在飞答复**：通道没有"取消这次请求"的语义（契约 §10 没有取消），所以"取消" =
  换一个代号，回来的旧答复对不上就丢掉 —— 它不会盖住新的结果。
- **不缓存、不预取**：候选随工作目录与所打的字变化，存一份就是第二个真值源。

## 8. 能力位

`repo.info.caps.references`（连接器侧 `referencesAvailable(ctx)`：`fileReferences` /
`sessionReferenceResolver` / `agents` 三键俱在才 true，**与挂不挂两个方法读同一个函数**）。

老连接器不报这个键 ⇒ 手机 `mentionsAvailable=false` ⇒ 面板整块不出现，
且**一个请求都不发**。这是诚实的空态，不是"这台电脑没有文件"。

`/` 的名单同理：`repo.info.commands` 缺席（老连接器 / `command.execute` 没挂）⇒ 不出菜单，
不是"没有命令可用"。

## 9. 已知边界

- 会话候选的 `mention` 里装着 DSH 会话 id 的 base64url —— 宿主的引用语法，
  它是 §5.1"手机只见 `sid`"的**有意例外**（契约 §5.7 那一行已写明）。
- 候选**不排序、不截断**：顺序与条数都是宿主的答案（上限 `candidateLimit` 由部署配）。
- **命令的说明是宿主定义里的原文**（`CommandDefinition.description`，英文），手机不做本地化：
  DSH 的 zh 文案在客户端词典里（`ui-commands/src/client/locales.ts`），我们没有那一层，
  手抄一份就会与宿主漂开。
- 文件行的说明是**父目录**，drill 之后不重复（面包屑已经说了在哪一层）。
- 会话行**没有位置与相对时间**：`refs.sessions` 只回 `{sid, title, mention}`，
  而宿主那一列是 `位置 · 相对时间`（`ui-reference/src/client/index.ts:264-292`）。
  要补就得给 `refs.sessions` 加字段（宿主有 `cwd` / `updatedAt`）。
- 失败文案是电脑侧原话，可能很长（截两行、不可展开）。
- **接管卡与面板同时在场**时两者从同一份预算里分空间：卡片先拿它不可压缩的两行（顶条 +
  动作行），面板拿剩下的；面板会被压到几行甚至 0 高。物理上没有更好的解 ——
  键盘弹起后可用高度只剩一小半。
