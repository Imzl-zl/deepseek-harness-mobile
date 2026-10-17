# 新会话页(blank 会话的 hero)

> 这一屏是**连接电脑后落到的第一屏**。范围只有这一屏 —— 左/右侧栏、插件页、设置页、
> 内嵌浏览器仍然只在电脑上(用户 2026-10-17 澄清:"我说的是刚连上的时候的页面,显示的不是 web 所有页面")。

## 1. 它不是"没有会话",是"已有会话但它是 blank"

DSH 的首页由 **blank** 决定,不是由"有没有会话"决定:

- `packages/client/ui-conversation/src/client/skeleton/ConversationMainPanel.tsx:41-43`
  的 `hero` 有两个来源,实际走后者:`sessionId === undefined || (shellPhase === 'blank' && (openState === 'open' || summaryBlank === true))`;
- 那个 blank 会话由**工作区连上时急切创建**:
  `packages/client/ui-workspace/src/client/navigation.ts:195-205` 的 `reuseOrCreateBlank()`;
- blank 期**没有任何内容区**:`skeleton/DefaultConversationViews.tsx:32` 直接 `return null`;
- 而 blank 会话在侧栏里是**藏起来**的(`ui-workspace/src/client/tree.ts:245`:
  `if (session.blank && id !== current) return false`)。

最后一条正是手机端必须有"落到它上面"这一步的原因:不选中它,用户在手机上**永远看不到这一屏**。

## 2. 结构

```
┌────────────────────────────────────────┐
│            🐟  探索未至之境 ˢᵘᵖ 预览版    │  HeroShell(.headline)
│  [📁 工作区 ⌄]   [◈ 模式 ⌄]            │  .heroWorkspaceRow
│  ┌──────────────────────────────────┐  │
│  │ 描述你想要构建的内容, / 调用指令, @… │  │  DshComposer(hero 变体)
│  │ ＋ 模型·等级 权限            ↑    │  │
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
```

装配点:`skeleton/ConversationContent.tsx:163-170` 的 `composerStack` ——
`HeroShell` → `.heroWorkspaceRow` → `[slot] conversation.input.dock` → `InputBar(variant='hero')`。
**输入栏不属于 hero**:DSH 的注解说得很清楚("The composer remains mounted outside this
component",`skeleton/EmptyHero.tsx:158-160`),手机侧同理(hero 只占对话区那块弹性空间,
输入卡片照旧是页面底部那一份)。

### 尺寸:桌面值 → 手机值

| 项 | 桌面(出处) | 手机 | 为什么 |
|---|---|---|---|
| 标题 | 26/32 w500(`HeroShell.module.css:41-43`) | **24/32 w500** | 手机排版刻度顶格是 24/32(`app/lib/theme/dsh_theme.dart` 的 `titleLarge`);不为这一屏新造一档字号 |
| 鱼 | 宽 34(`EmptyHero.tsx:104-105`) | **34** | 它是**标记不是文字**:34px 在手机上仍是个小图形(占宽 8%),缩它会先于标题失真 |
| chip 高 | `min-height: 28px`(`HeroShell.module.css:157`) | **44** | 28px 低于可点下限:Flutter 的 `kMinInteractiveDimensionCupertino = 44.0`(`packages/flutter/lib/src/cupertino/constants.dart:29`)、Material 是 48(`material/constants.dart:27`);取 44 是因为这一屏要并排放两枚 |
| 卡片宽 | `max-width` 712–952px(`ConversationRoot.module.css:384-389`) | **撑满可用宽** | 照搬那个像素值等于把手机上的卡片缩到屏幕一半 |
| hover 游动 | SMIL 形变(`EmptyHero.tsx:111-121`) | **不做** | 触屏没有 hover |

其余照 DSH 原值:`.stack` gap 12(`HeroShell.module.css:20`)、标题与鱼 column-gap 10(`:35`)、
标题与徽标 column-gap 7(`:57`)、徽标 padding 1/7 + 圆角 999 + 等宽 12px(`:62-76`)、
chip 内 gap 4 与 `padding 0 8px`(`:152-167`)、chip 行左缩进 8(`:145`)、
文件夹 16px 与 chevron 12px(`EmptyHero.tsx:56-59`)、模式 chip 与工作区 chip **同形**
(`AgentPresetSeat.module.css:1-2`:"Geometry mirrors HeroShell's .workspace so the two
read as one row")。

### 文案(逐字,不改写)

| 位置 | 文案 | 出处 |
|---|---|---|
| 标题 | 探索未至之境 | `ui-conversation/src/client/locales.ts:77` |
| 徽标 | 预览版 | `:78`,**无条件渲染**(`EmptyHero.tsx:155`),没有开关 |
| 工作区占位 | 选择工作区 | `:79` |
| 输入框占位 | 描述你想要构建的内容, / 调用指令, @ 文件或对话 | `:23` 的 `placeholder.hero` |
| 预设无描述 | 暂无描述。 | `ui-agent-preset/src/client/locales.ts:106` |

**两套占位符都是半角逗号**;普通会话那句在 `:20` 的 `placeholder.default`。

## 3. 三样数据

| 要显示的 | 来源 | 备注 |
|---|---|---|
| 工作区 chip 的标签 | `workspace.list` 的归属(`WorkspaceView.sessionIds`) | 手机侧的会话行**没有** `workspaceId`,归属只此一处 |
| 模式 chip 的标签 | `agentPreset` **投影**(`string \| null`) | `agent-preset-registry/src/session.ts:35-44`;随已有的 `session.projections` 到手机,不占方法面 |
| 模式选择器的名单 | `agentPresets.list`(连接器) | `@Remote('list')` → `remoteExportList()`,契约 §5.7 |

### 工作区标签链(逐条照 `ConversationContent.tsx:89-108`)

1. 刚选过的那个(pending)→ 它的标题;
2. 这个 blank 会话的工作区在清单里 → 它的标题;
3. 清单**还没到** → 用 `cwd` 的目录名顶一下(空 `cwd` → 占位);
4. 清单**到了但没有归属**(如已从侧栏删掉)→ **占位,绝不拿已删目录的名字通过 `cwd` 顶上**。

第 4 条是整条链里唯一有安全性的一条:一个被删掉的工作区目录还躺在会话的 `cwd` 里,
用它当标题会让用户以为那个工作区还活着。目录名的取法与 DSH 的 `workspaceTitleOf`
逐字一致(`packages/util/workspace-path/src/index.ts:58-62`,两种分隔符都认;
只有**整条都是分隔符**的路径回空串)。

### 预设显示名(逐字移植 `agent-preset-registry/src/display.ts:53-73`)

- **内置四档走本地化字典**:`standard` 标准模式 / `ptc` PTC 模式 / `minimal` 极简模式 /
  `cordis` 创造模式(id 表在 `display.ts:41-44`,文案在
  `ui-agent-preset/src/client/locales.ts:95-102`);
- **用户自建的元数据永不翻译**:判据是 `name === undefined && id 在内置表里`
  (`isBuiltInPreset`,`display.ts:53-55`)—— 一个自己起名 `standard` 的预设是"自建";
- **名单原样过线,过滤发生在手机侧**:`broken === undefined` 才是可选,而"选择器只列可用的、
  管理页列全部"是 Web 的两份不同规则(`ui-agent-preset/src/client/settings-store.ts:119-127`
  与 `:109-110`)。连接器按 broken 过滤一次,就等于替这一屏决定了它是不是管理页。

## 4. 写路径:建会话时带上,不用 `agentPresets.select`

DSH 的 hero chip 走 `remote.agentPresets.select(sessionId, id)`
(`ui-agent-preset/src/client/seat-store.ts:230`),而它**对跑过一轮的会话会拒**
(`agent-preset-registry/src/index.ts:351` 抛 `agent-preset/locked`)。

手机侧的写路径是 **`session.create({workspaceId, agentPreset})`**:
`SessionCreateRequest` 本来就收这两个字段(`packages/api/session-controller/src/types.ts:288-293`),
连接器的 `session.create` 也一直在透传(`connector/src/handlers.ts`)。于是:

- **方法面只 +1(读)**:新增的唯一方法是 `agentPresets.list`;
- 选预设 = **开一个新任务**(与 DSH 的立场一致:"这个选择只在会话开始前成立",
  `AgentPresetSeat.tsx:4-9`);
- **代价(已知并接受)**:每换一次选择会留下一个 blank 会话。blank 会话两边都不列,
  且 DSH 的 `reuseOrCreateBlank()` 以后会复用它,所以不会无限增长;
  选中的就是当前那一项时**什么都不做**(点一下不该多出一个会话)。

取舍与被否方案见 `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。

## 5. 什么时候落到这一屏

没有选中会话时,取**第一个 blank 且非子智能体**的会话并打开它 ——
这一步对应 DSH 的 `reuseOrCreateBlank()`,但**只复用不新建**(电脑侧已经有一个了,
`session.create` 只会多造一个)。挑不到 blank 就什么都不做:主界面照旧是内联会话列表
(那是"首页就该看得见的东西"那条真机结论,不因为 hero 而撤销)。

hero 与空态的分界,一句话:**blank 会话 → hero;其余空屏 → 原来的空态**
(没配对 / 连不上 / 拉取失败,三种都要分开说,不因为加了 hero 而合并)。

## 6. 明确不做

拖拽上传、**"添加工作区…"的目录选择器**(走 Host 同机的系统文件夹对话框,
`ui-directory-picker-native/README.md:12,28,34`)、hover 游动、快捷键提示、
`<input type=file multiple>` 原生多选、滚轮链式传递、列宽拖拽手柄、Electron 窗口 chrome。
**hero 下面也不塞历史会话列表** —— blank 期 DSH 没有任何内容区。

## 7. 验证

| 断言组 | 命令 | 项数 |
|---|---|---|
| 标签链 / 目录解析 / 显示名(纯 Dart) | `cd app; flutter test test/agent_preset_test.dart test/workspace_grouping_test.dart` | 10 + 7 |
| hero 的出现条件、两枚 chip 的写路径 | `cd app; flutter test test/conversation_hero_test.dart` | 13 |
| 原型布局与交互 | `node mock/proto/tools/verify-proto.mjs` | 18(该脚本共 31) |
| 预设目录(连接器) | `cd connector; pnpm test` | `tests/agent-presets.test.ts` 6 条 |

改动落在哪:原型在 `mock/proto/index.html` 的 `#convHero` + `styles.css` 的「新会话页(blank)的 hero」
一节 + `app.js` 的 `setBlankSession`;落地端在 `app/lib/ui/conversation_hero.dart`、
`app/lib/model/agent_preset.dart`、`app/lib/model/workspace.dart`(标签链)、
`app/lib/data/app_model.dart`(`_openBlankSessionIfUnselected` / `agentPresetRoster`)、
`app/lib/ui/chat_page.dart`(两枚 chip 的 sheet 与 `_startSession`)。
