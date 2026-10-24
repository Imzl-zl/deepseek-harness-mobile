# Agent Note: `@` 文件与会话提及 —— 两个只读窄口 + 一张面板，判据与宿主同一条

Status: implemented

## Problem

输入框的占位符一直写着「@ 文件或对话」（DSH 原文），但**手机上没有那张面板**：
打一个 `@` 什么都不会发生。用户只能自己在外面记住路径、手打，或者根本不用这个功能。

2026-10-24 之前这条被记成"重活"，理由是我们以为 `@` 需要一个结构化编码
（消息里带 `{type:'mention', ...}` 之类）。核实后**不成立**：

- `@` 与 `/` 是**同一个输入触发器框架**（`packages/client/ui-input-trigger/src/types.ts:34`
  的 `TriggerChar = '/' | '@'`）。
- `@` 的 token 是**普通文本**，宿主拿词表匹配
  （`packages/client/ui-conversation/src/client/input/decorations.ts:24-25`：
  `TEXT_REF_RE = /(^|\s)([/@])([\w-]+)/g`、`FOLDER_REF_RE`；触发符必须在**草稿开头或空白之后**，
  名字段不含空白、不跨行）。
- 背后两个 Remote 都**已经存在**，手机只需要透传：
  `fileReferences.list(agent, query, signal)` → `{path, kind}`（`packages/api/session-controller/src/file-references.ts:32-39`）
  与 `sessionReferenceResolver` 的 `@Remote('candidates')`（`packages/context/session-reference/src/index.ts:281-295`，
  **直接返回拼好的 `mention` 文本**）。

所以缺的只是"两个只读方法 + 一张面板"，不是一套新语法。

## Decision

**连接器（`refs.files` / `refs.sessions`）**

1. 两个方法都**只透传**：不排序、不截断、不缓存。候选上限是宿主的 `candidateLimit`，
   抄到我们这边就是第二份真值（电脑侧调配置，手机永远只看到旧上限）。
2. 空结果 = **空数组**（宿主说"这里没有匹配"）；宿主抛错**原样过线**（分发器归 `internal`，
   消息保留原话）—— 手机显示的原因必须是电脑侧说的那句，不能是我们编的。
3. 能力位 `caps.references` 与"挂不挂这两个方法"读**同一个函数**
   （`dsh/caps.ts` 的 `referencesAvailable`，三个服务键：`fileReferences` /
   `sessionReferenceResolver` / `agents`）。两处各写一遍就会漂成
   "`repo.info` 说有能力、`methods` 里却没有"—— 那正是手机上一个点了没反应的按钮。
   **两个面同生同死**：只有一个面时面板要么只列文件、要么只列会话，用户得猜"为什么少一半"。
4. 会话候选行 `{sid, title, mention}`：`title` 取 `displayTitle ?? label`（宿主拼 mention 时同一句，
   `:290-293`）；`sid` 是**先查再分配**的别名（`session.list` 已为可见会话分过，第二档只覆盖
   "会话刚建、列表还没刷"的窗口）；`mention` **原样过线**。

**手机（`app/lib/model/mention.dart` + `ui/dsh_composer.dart` 的 `_AtSuggestions`）**

5. 触发判据与宿主**逐条对齐**（`atTriggerOf`）：`@` 在草稿开头或空白之后、token 里没有空白
   （于是也不跨行）、取最后一个 `@`。
6. 去抖 **150 ms**、新按键**作废在飞答复**（通道没有"取消这次请求"的语义，所以"取消" = 换代号、
   回来的旧答复对不上就丢掉）、**不缓存不预取**。
7. 三态各一句话：列表 / 空（"没有匹配的文件或会话"）/ **失败显示电脑侧给的原因**。
8. 选中只插**纯文本**：文件 `@path`、目录 `@path/`（补一个斜杠，与宿主的目录 token 同形）、
   会话用宿主的 `mention` 一个字符都不改。**只替换那一个 token**，前面的正文原样留着。
9. 老连接器（`repo.info.caps.references` 缺席）⇒ `mentionsAvailable=false` ⇒ 面板整块不出现，
   **也一个请求都不发**。

## Alternatives considered

1. **手机侧自己做文件索引 / 解析路径归属** —— 最强理由：零连接器改动、面板可以本地即时出结果。
   被否：工作目录归属与"这份目录里有什么"只有宿主知道（候选来自 `FileReferenceService`，
   它按 agent 的 cwd 枚举）；手机侧建一份索引就是第二个真值源，而且必然过期。
2. **结构化编码（消息里带 mention 对象）** —— 最强理由：手机侧好渲染、好校验。
   被否：宿主读的就是文本 token（`decorations.ts` 的两条正则 + 会话那条
   `parseSessionReferenceText` 只认 `dsh-session:` URI），结构化编码在宿主眼里是**普通文本**；
   而契约 §5.7 的载荷形状单源是"内容块 + `submittedAttachments`"，消息体里不该出现自家语法。
3. **候选上限抄到连接器（只发前 8 条）** —— 被否：`candidateLimit` 是部署可配的
   （`session-reference/src/index.ts:106` 的 Config），抄一份＝第二份真值。
4. **把 `mention` 换成 `@标题`** —— 被否：宿主认不出，引用不生效。URI 里装的是 DSH 会话 id 的
   base64url，那是宿主的引用语法，我们只当不透明文本搬运（代价见下）。
5. **底部 sheet 弹候选** —— 同 `/` 候选笔记的被否理由：候选必须与输入框同屏
   （sheet 会把输入框盖住）。
6. **目录不补斜杠** —— 被否：宿主的目录 token 以 `/` 结尾（`FOLDER_REF_RE`），补斜杠才"接着往里打"；
   不补的话下一个字符就落在一个**完整 token** 后面，面板立刻消失。

## Consequences

- **收益**：`@` 从"记得住才用得上"变成"打一个 `@` 就看见"；文件、目录、跨会话引用走同一条路；
  名单与上限仍然只有宿主一处。
- **代价（通道层）**：一次面板打开 = 两个请求（`refs.files` + `refs.sessions`）。串行只是多等一个往返，
  所以并发发；去抖 150 ms 让连续打字只落到最后一次。
- **代价（越线）**：会话候选的 `mention` 里**带着 DSH 会话 id 的 base64url**。它必须过线
  （宿主按它解析引用），所以 §5.1 的"手机只见 `sid`"在这一行有个**有意的例外**，
  已在契约 §5.7 的 `refs.sessions` 行写明。
- **代价（别名表）**：候选行带 `sid` ⇒ 对"从未打开过、也不在列表里"的会话会分配一个别名。
  绝大多数命中第一档（`session.list` 已分过），第二档只是窗口期的兜底。
- **代价（失败文案）**：失败态直接显示电脑侧原话，可能很长（截两行）。

## 判据

- connector **621 → 629**（`tests/references.test.ts` 8 条）：方法表 + `refs.files` 有/空 +
  `refs.sessions` 有/空 + 宿主抛错原样 + caps 有 + caps 缺（三种缺法各判一次）。
- flutter **1175 → 1189**（`test/mentions_test.dart` 14 条）：触发判据 3 条 + 插入文本 2 条 +
  界面三态（列表/空/失败）+ 老连接器不发请求 + 插入后不留面板 + 能力位两条 + `queryMentions` 两条。
- boundary **369 → 372**（新增 `app/lib/model/mention.dart`）。
- **变异校验两组，各恰好一条红，做完即还原**：
  ① 把 `atTriggerOf` 的"必须在行首或空白之后"删掉 ⇒ 只有「正文中间的 `@` 不是引用」红；
  ② 把 `referencesAvailable` 写成恒真 ⇒ 只有「缺任一服务 ⇒ 能力位 false 且两个方法都不挂」红。
- `pnpm exec tsc --noEmit` 0、`pnpm build` 过、`dart analyze --fatal-infos` 0、`dart format` 0。

## 真机验证（2026-10-24，隔离实例 + adb）

**结论：`@` 面板在真机上能用，但暴露了一个单测抓不到的 bug —— 已修。**

- **`Duplicate keys found`（整屏红）**：候选胶囊的 key 原来只由 `kind + label` 组成，
  而这台机器的会话里有 **40 个同名会话**（`List numbers 1 to 40`）⇒ 同一批候选里
  key 重复 ⇒ Flutter 直接红屏。**修法：key 带下标**（`at-<index>-<kind>-<label>`），
  并补一条回归用例（两个同名会话同时出现）。
- **面板没有高度上限**：40 多个候选把输入栏那一列撑爆（同屏还报了 `overflowed`）。
  **修法：`ConstrainedBox(maxHeight: 132)` + `SingleChildScrollView`** ——
  候选条数仍由宿主决定（不截断），只是把它放进一个能滚的窗口。
- 其余确认可用：打 `@` 后候选项来自宿主（工作区根的真实目录 `app` / `artifacts` /
  `connector` / `docs`）；点一个文件 ⇒ 输入框变成 `@app/test/agent_preset_test.dart`
  （**文件不带尾斜杠**，与探针规则一致），面板随即收起。
- 同一轮真机还确认了**文件页**（列真实工作区、`AGENTS.md` 预览中文正常）、
  **插件页**（宿主的本地化名、只读原因、**启停真的写进了 profile patch**：
  `cordis.patch.yml` 里出现 `disabled: true`，再点一次变 `disabled: false`）、
  `/plan` 命令卡（`Plan mode on. Use /plan off to leave.`）。
- **另发现一个既有缺陷（与本轮功能无关）**：接管卡（提问）在**键盘弹出时溢约 200px**
  （`BOTTOM OVERFLOWED BY 204 PIXELS`），卡片底部的「跳过 / 提交」被顶出屏幕 ——
  已记进 `memory.md` 的已知缺口，待单独修。

## 代码入口回指

- 连接器：`connector/src/dsh/references.ts`（两个面 + 形状收窄）、
  `connector/src/dsh/caps.ts` 的 `referencesAvailable`、`connector/src/index.ts` 的挂载点、
  `connector/src/handlers.ts` 的 `refs.files` / `refs.sessions`。
- 手机：`app/lib/model/mention.dart`（`atTriggerOf` / `insertAtMention` / 三条插入规则）、
  `app/lib/ui/dsh_composer.dart` 的 `_AtSuggestions`、
  `app/lib/data/app_model.dart` 的 `mentionsAvailable` / `queryMentions`、
  装配点 `app/lib/ui/chat_page.dart`。
- 契约：`docs/subsystems/remote-channel.md` §5.7 的两行；现状见
  `docs/subsystems/composer-mentions.md`。
