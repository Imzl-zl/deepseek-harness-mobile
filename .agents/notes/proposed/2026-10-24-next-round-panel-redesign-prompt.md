# 下一轮提示词：`@` / `/` 候选面板重做（照宿主列表形状）+ 真机尾巴

> 用法：新会话整段复制粘贴（或直接读这个文件）。
> **这一轮写代码**。方向已由用户定案（"居中的胶囊丑、要目录式/父子级"），不要再论证"要不要做"，只需论证"怎么照宿主做对"。
> 预期成本：**0 次模型请求**；真机只在最后验观感（可选，约 1 个模型请求）。

---

## 0. 现状（本轮结束后的事实，别再重查）

项目 `D:\sudy\myproject\dsh-mobile`（Windows / pwsh，中文回复）。
`connector/`（TS，DSH 插件）+ `relay/` + `app/`（Flutter）+ `protocol/` + `docs/`。
DSH 参考源码（只读）：`D:\sudy\github\deepseek-harness`，**0.2.1-rc.3**。

**先读**：`AGENTS.md`（铁律）、`memory.md`（尤其"2026-10-24 真机"那节与"已知缺口"）、
`docs/subsystems/composer-mentions.md`、`docs/subsystems/files-page.md`、
`.agents/notes/implemented/2026-10-24-file-and-session-mentions.md`。

**门禁（全绿，改完不许红）**：connector **655**、flutter **1221**、boundary **391**、
`dart analyze --fatal-infos` 0、`dart format` 0（跑 `lib test integration_test`，**不要**对 `app/` 整目录跑，
`app/tools/dsh_icons.template.dart` 含 `@@ART@@` 会让 format 退出 65）、契约方法面 **49 / 实现 47**。

**上一轮已交付**（都已推）：`@` 文件+会话候选（`refs.files` / `refs.sessions`）、用量四档、
插件清单/启停、图片上限读 `imageLimits`、计划审查卡（来自 `exit_plan_mode` 的 `tool/call`）、
文件页（`file.list` / `file.read`）、插件安装/卸载（发起即返回 + 轮询）、
插件安装只收 registry/git 来源。

---

## 1. 用户原话（本轮要解决的问题）

> 「UI 有点丑啊，啥布局啊都是，居中的，为啥不是目录那种，起码美观一点是吧？
> 你文件肯定父子级吧？可以嵌套的吧？还有命令的也是。」

三件事：
1. **`@` 候选现在是居中的胶囊（`Wrap`）**，要改成**列表行**：左对齐、图标 + 名字、可读的层级。
2. **文件要父子级**：目录能进去、能回来（DSH 的原样是 drill + 面包屑，见 §2）。
3. **`/` 命令候选也一样**（现在也是胶囊，且只有名字、没有说明）。

---

## 2. 宿主的原样（**照这个做**，`packages/client/ui-input-trigger/src/client/`）

`MenuView.tsx` + `MenuView.module.css` 是候选菜单的唯一真值。

**面板本体**
- 贴在输入卡**上方**、**与卡片同宽**（`position:absolute; bottom:calc(100% + 4px); left:0; right:0`）。
- `max-height: 400px`，且运行时按"输入卡上方可用高度"再收紧（`useAnchoredMaxHeight(listRef, 400, state, TOP_MARGIN)`，
  `TOP_MARGIN = 84` = 会话头部 76px + 8px）；`overflow-y:auto`；滚到底出现渐变提示（`data-overflow-below`）。
- 容器是 `MenuSurface`（浮层）：`padding:4px`、`border-radius: lg`、`box-shadow: elevation-prominent`。
- **分组标题**（`.groupTitle` / `.sectionTitle`）：11px / 500 / `label-tertiary`，`min-height:23px`，`padding:5px 8px 2px`。
- pending 时给**两行骨架**（`skeletonRow` + 32% / 48% 宽的 `skeletonBar`），不是空白。

**一行（`.item`）**
```
display:flex; align-items:center; gap:6px; width:100%;
min-height:34px; padding:6px 8px; border-radius: md;
font-size:13px; line-height:20px; text-align:left;
```
行内顺序：**icon(14px)** → **名字** → **别名**（`label` 与 `name` 不同且不是同一字母大小写时）
→ **说明**（`.itemDescription`，右侧）→ 目录行末尾的 **chevron（12px）+ drill 提示**。
高亮只有一个来源（`.item.active`，指针移动与键盘共用）。

**`@` 的数据形状**（`packages/client/ui-reference/src/client/index.ts`）
- source `reference`，`showGroupTitle: false`，每行带 `section`：**`文件` / `会话`**（本地化词，`:258`、`:290`）。
- 文件行：`icon: 'folder' | 'file'`（`:257`）、`description` = **父目录**（`:256`，根目录行没有说明）、
  **目录行 `drill: true`**（`:260`）。
- 会话行：`icon: 'session'`（`:288`）、`description` = `位置 · 相对时间`（`:287`）。
- **drill 的语义**（`:131-148`）：目录行的"落定选择"把该目录作为引用插入（`label + '/'`），
  而 `action: 'drill'`（Tab / 行尾 chevron / 面包屑）**返回 `{text: mention, continue: true}` —— 菜单不关**。
- **面包屑只在 drill 时出现**（`:199-226` 的 `crumbsFor`：`drilled === false` 直接 `undefined`）：
  根 → 各段，最后一段 `current`（不可点）。理由原话：手打的路径自带上下文（在草稿里），
  而 drill 把用户正在读的文本换成了更深的一段，欠他一条回去的路。
- 目录插入后**继续往里打字**（`@src/` 之后就是新查询），这条我们已经对了（`insertAtMention` 补 `/`）。

**`/` 的数据形状**
- 行同样是 `.item`：名字 + 别名 + **说明右对齐**。说明来自命令定义（`commands.register({name, description})`）。
- 我们的 `repo.info.commands` 目前只发**名字数组**（`['goal','plan']`）⇒ 手机没有说明可显示。
  **要么不发说明（只做列表行），要么把它改成 `{name, description?}`（见 §3 任务 B）。**

---

## 3. 任务

### A（主活）把 `@` 与 `/` 候选改成宿主的列表形状

**手机侧**（`app/lib/ui/dsh_composer.dart`）：
1. 把 `Wrap` + `_SuggestionChip` 换成**一个列表**：`_SuggestionPanel`（按 `section` 分组、组标题、行）。
   行 = 图标 + 名字 + 右侧说明 + 目录行的 chevron；行高 `minHeight 34`、`padding 6/8`、圆角 `DshRadius.sm`。
   图标走 `DshIcon`：目录 `folderClose`、文件 `deliverDoc`、会话 `cordisPlugin`？——
   **先查 `app/lib/theme/dsh_icons.dart` 里有没有 folder/file/session 三档**，没有就用最接近的并在笔记里写明。
2. **高度**：`约束到"输入卡上方可用高度"`（照 `useAnchoredMaxHeight`：`MediaQuery.size.height - viewInsets.bottom`
   的某个比例，或直接用 `LayoutBuilder` 取剩余空间，**不需要搬 84px 那个常数** —— 那是桌面的头部高度）。
   列表内部滚，滚到底给渐变提示（可选）。
3. **drill + 面包屑**：目录行点**行尾 chevron** = drill（把 `@父/子/` 填进输入框、面板保持打开、显示面包屑）；
   点**行本身** = 落定（插入 `@path/` 并关面板）。面包屑只在 drill 之后出现，根 + 各段，点某段回那一层。
   - 需要 `AtCandidate` 增加 `parent`（文件行的父目录，用于右侧说明）——由 `refs.files` 的 `path` 推导即可，**不新增字段**。
4. **分组**：`文件` / `会话` 两个 section title；`/` 那边一个 section（"命令"）或直接不分组。
5. **pending 两行骨架**（现在是"正在找…"一句话，可以保留一句，但用户点开时先给骨架更像宿主）。
6. 三态（列表 / 空 / 失败）保留；失败态**保持一句话**（宿主的错误是 toast，不占列表）。
7. 选中/插入规则**一个字都不许改**：文件 `@path`、目录 `@path/`、会话用宿主 `mention` 原样。

**判据（flutter）**：行是左对齐列表（断言行的 `Row`/`Align` 或快照式断言"第一行文本 x 起点 < 面板中心"）；
目录行有 chevron 且点它**不关面板**、输入框变 `@a/b/`；点行体插入 `@a/b/` 并关；面包屑在 drill 后出现、
点根回根层；分组标题出现（文件/会话）；`/` 也是列表行。**变异校验**：把 drill 改成"点行体也 drill" ⇒ 恰好一条红。

### B `/` 命令的说明（可选，但用户点名了"命令的也是"）

- 连接器 `repo.info.commands` 从 `string[]` 改成 `{name, description?}[]`（**向后兼容**：手机两种都收）。
  说明来自 `commands.register` 的定义（`packages/interaction/commands/src/index.ts` 的 definition）；
  白名单 `MOBILE_COMMANDS` 里补上两条的说明**从宿主读**（不手抄文案）。
- 契约 §5.7 的 `repo.info` 行 + `tools.md` + `memory.md` 同批改。
- 判据：connector 一条（发对象数组）；flutter 一条（两种形状都收；说明右对齐）。

### C 修接管卡溢出（真机抓到，既有缺陷）

真机：提问卡 + 键盘同时在场 `BOTTOM OVERFLOWED BY 204 PIXELS`，卡底「跳过 / 提交」被顶出屏幕
（证据 `D:\tmp\dsh-e2e\shots-2026-10-24-mentions\h1-typed.png`）。
- 查 `app/lib/ui/takeover.dart`：`takeoverMaxHeightFor(context, fraction)` 用的是
  `(size.height - viewInsets.bottom) * fraction`，而卡片整体（顶条 + 主体 + 动作行）在
  `chat_page.dart` 的 `Column` 里与输入栏竞争空间 —— 溢出说明某处是**固定高度/不受约束的 Column**。
- 修法方向：给整卡一个 `Flexible`/`ConstrainedBox`，让**动作行恒可见、主体先滚**（文件里已有这条注释，但没生效）。
- 判据：widget 测试模拟 `viewInsets.bottom > 0` + 一条 3 选项提问 ⇒ 无 overflow 异常、提交按钮可点。

### D 真机尾巴（可选，最后做）

- **计划审查卡**（唯一没走到真机的功能）：进会话 → `/plan` → 发一句**用 `%s` 代空格**的英文 prompt
  （`adb shell input text` 的空格必须写 `%s`，否则消息在第一个空格前被截断 —— 上一轮就是这么翻车的）
  → 等 60–90 s → 计划卡应出现（标题「等待确认计划」+ 正文）→ 点「同意执行」→ 会话日志应出现 `plan/mode(active:false)`。
- 图片上限四条（把隔离实例的 `maxImageBytes` 调小，再选图）。
- 插件安装/卸载的真实 pnpm 流程（用 registry 来源，装完卸载）。
- 真机环境与坑见 `tools.md` 的「真机」小节 + `memory.md` 的真机那节。

---

## 4. 硬规则（违反即返工）

- **不新增宿主没有的语义**：列表形状、drill、面包屑、分组、说明右对齐**全部照 §2**；
  不要自己发明"内联展开的树"（DSH 是 drill 不是 inline tree）。真想要 inline tree，先改 `docs/` 并写决策笔记指明这是**有意偏离**。
- 通道层参数可以自己定（面板最大高度的比例、滚到底的渐隐、以及已有的 150 ms 去抖），**但业务规则不许塞进去**。
- 改源码**只用编辑工具**（`edit`/`write`），不用 shell 字符串替换；提交前看完整 `git status`。
- 契约 §5.7、`docs/subsystems/composer-mentions.md`、`memory.md`、`tools.md` **同批改**（门禁数、方法数、项数）。
- 引用 DSH 行为给 `packages/...:行号`；查不到写「未找到」。
- 每个任务一个提交 + 一篇 `implemented/<日期>-<slug>.md`（含 Alternatives considered 与代价）。

---

## 5. 起手命令

```powershell
cd D:\sudy\myproject\dsh-mobile
git log --oneline -3; git status --short
Select-String -Path app\lib\ui\dsh_composer.dart -Pattern "class _AtSuggestions|class _SlashSuggestions|_SuggestionChip|maxHeight" -Context 0,12
Select-String -Path app\lib\model\mention.dart -Pattern "class AtCandidate|insertAtMention|atTriggerOf" -Context 0,10
node app\tools\flutter-api.mjs ListView            # Flutter 行为查证（本机 SDK 源码）
# 宿主菜单的真值（只读）
Get-Content D:\sudy\github\deepseek-harness\packages\client\ui-input-trigger\src\client\MenuView.module.css
Get-Content D:\sudy\github\deepseek-harness\packages\client\ui-reference\src\client\index.ts | Select-Object -Skip 240 -First 55
```

---

## 6. 明确不做（别花时间）

- 插件的**安装/卸载/升级**再扩（已经做了安装/卸载；升级 `updateBundle` 仍不做）。
- **后台送达 / 厂商推送**（已定案）。
- **逐插件配置页**（DSH 没有通用渲染器）。
- 别把 `@` 面板做成"文件树常驻侧栏" —— 用户要的是**候选面板**里的层级，不是一个新页面。
